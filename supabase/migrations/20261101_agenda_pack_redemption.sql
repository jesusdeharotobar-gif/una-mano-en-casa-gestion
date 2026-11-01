-- Agenda: canjear packs de 6/12 h en bloques elegibles de 3, 6, 9 o 12 h.
-- Requiere que public.es_administrador() ya exista.
-- Se puede ejecutar más de una vez.
begin;

alter table public."Citas"
  add column if not exists "Pack_id" bigint;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public."Citas"'::regclass
      and conname = 'Citas_Pack_id_fkey'
  ) then
    alter table public."Citas"
      add constraint "Citas_Pack_id_fkey"
      foreign key ("Pack_id") references public."Packs" (id);
  end if;
end;
$$;

create or replace function public.guardar_cita_con_pack(
  p_cita_id bigint,
  p_cliente_id bigint,
  p_pack_id bigint,
  p_fecha_hora timestamptz,
  p_servicio text,
  p_duracion_horas numeric,
  p_precio numeric,
  p_estado text,
  p_metodo_pago text,
  p_notas text
)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cita public."Citas"%rowtype;
  v_pack public."Packs"%rowtype;
  v_is_new boolean := p_cita_id is null;
  v_must_reserve boolean;
  v_must_restore boolean := false;
  v_restore_hours numeric := 0;
  v_reserve_hours numeric := 0;
  v_old_pack_id bigint;
  v_result_id bigint;
begin
  if not public.es_administrador() then
    raise exception 'No tienes permiso para gestionar citas y packs.' using errcode = '42501';
  end if;
  if p_cliente_id is null or p_fecha_hora is null or nullif(btrim(p_servicio), '') is null
     or p_duracion_horas is null or p_duracion_horas <= 0 or p_precio is null or p_precio < 0
     or nullif(btrim(p_estado), '') is null then
    raise exception 'Faltan datos obligatorios de la cita.' using errcode = '22023';
  end if;
  if p_pack_id is not null and (p_duracion_horas not in (3, 6, 9, 12) or p_precio <> 0) then
    raise exception 'Una cita con pack debe canjear 3, 6, 9 o 12 horas y tener precio 0.' using errcode = '22023';
  end if;

  if not v_is_new then
    select * into v_cita from public."Citas" where id = p_cita_id for update;
    if not found then raise exception 'No se encontró la cita.' using errcode = 'P0002'; end if;
    v_old_pack_id := v_cita."Pack_id";
    if v_cita."Estado" = 'Completada'
       and (p_estado <> 'Completada' or v_cita."Pack_id" is distinct from p_pack_id
            or (v_cita."Pack_id" is not null and v_cita."Duracion_horas" is distinct from p_duracion_horas)) then
      raise exception 'Una cita completada conserva las horas de pack que ya consumió.' using errcode = '22023';
    end if;
  end if;

  if not v_is_new and v_cita."Pack_id" is not null and v_cita."Estado" not in ('Cancelada', 'Completada') then
    if v_cita."Pack_id" is distinct from p_pack_id or p_estado = 'Cancelada' then
      v_restore_hours := v_cita."Duracion_horas";
    elsif p_duracion_horas < v_cita."Duracion_horas" then
      v_restore_hours := v_cita."Duracion_horas" - p_duracion_horas;
    end if;
  end if;
  v_must_restore := v_restore_hours > 0;

  if p_pack_id is not null and p_estado <> 'Cancelada' then
    if v_is_new or v_cita."Estado" = 'Cancelada' or v_cita."Pack_id" is distinct from p_pack_id then
      v_reserve_hours := p_duracion_horas;
    elsif p_duracion_horas > v_cita."Duracion_horas" then
      v_reserve_hours := p_duracion_horas - v_cita."Duracion_horas";
    end if;
  end if;
  -- Lock any involved packs by ID to serialize block changes and avoid deadlocks.
  perform 1 from public."Packs"
    where id = p_pack_id or (v_must_restore and id = v_old_pack_id)
    order by id for update;
  if p_pack_id is not null then
    select * into v_pack from public."Packs" where id = p_pack_id for update;
    if not found then raise exception 'No se encontró el pack seleccionado.' using errcode = 'P0002'; end if;
  end if;

  if v_must_restore then
    update public."Packs"
      set "Horas_disponibles" = coalesce("Horas_disponibles", 0) + v_restore_hours,
          "Estado" = case
            when "Estado" = 'Agotado' and ("Fecha_caducidad" is null or "Fecha_caducidad" >= current_date) then 'Activo'
            else "Estado"
          end
      where id = v_cita."Pack_id";
  end if;

  v_must_reserve := v_reserve_hours > 0;

  if p_pack_id is not null then
    if v_pack."Cliente_id" is distinct from p_cliente_id then
      raise exception 'El pack debe pertenecer al mismo cliente de la cita.' using errcode = '22023';
    end if;
    if v_pack."Tipo_pack" not in ('Pack 6 Horas (Canjeable)', 'Pack 12 Horas (Canjeable)') then
      raise exception 'Solo se pueden canjear packs de 6 o 12 horas.' using errcode = '22023';
    end if;
    if (v_pack."Tipo_pack" = 'Pack 6 Horas (Canjeable)' and p_duracion_horas > 6)
       or (v_pack."Tipo_pack" = 'Pack 12 Horas (Canjeable)' and p_duracion_horas > 12) then
      raise exception 'La duración elegida supera las horas totales del pack.' using errcode = '22023';
    end if;
    if v_must_reserve and (v_pack."Estado" <> 'Activo' or (v_pack."Fecha_caducidad" is not null and v_pack."Fecha_caducidad" < current_date)) then
      raise exception 'El pack está inactivo o caducado.' using errcode = '22023';
    end if;
    if v_must_reserve and coalesce(v_pack."Horas_disponibles", 0) < v_reserve_hours then
      raise exception 'El pack no tiene suficientes horas disponibles para este canje.' using errcode = '22023';
    end if;
  end if;

  if v_must_reserve then
    update public."Packs"
      set "Horas_disponibles" = "Horas_disponibles" - v_reserve_hours,
          "Estado" = case when "Horas_disponibles" - v_reserve_hours < 3 then 'Agotado' else "Estado" end
      where id = p_pack_id;
  end if;

  if v_is_new then
    insert into public."Citas" ("Cliente_id", "Pack_id", "Fecha_hora", "Servicio", "Precio", "Estado", "Método de pago", "Duracion_horas", "Notas")
    values (p_cliente_id, p_pack_id, p_fecha_hora, btrim(p_servicio), p_precio, p_estado, p_metodo_pago, p_duracion_horas, p_notas)
    returning id into v_result_id;
  else
    update public."Citas"
      set "Cliente_id" = p_cliente_id, "Pack_id" = p_pack_id, "Fecha_hora" = p_fecha_hora,
          "Servicio" = btrim(p_servicio), "Precio" = p_precio, "Estado" = p_estado,
          "Método de pago" = p_metodo_pago, "Duracion_horas" = p_duracion_horas, "Notas" = p_notas
      where id = p_cita_id returning id into v_result_id;
  end if;
  return v_result_id;
end;
$$;

create or replace function public.cancelar_cita_con_pack(p_cita_id bigint)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cita public."Citas"%rowtype;
begin
  if not public.es_administrador() then
    raise exception 'No tienes permiso para gestionar citas y packs.' using errcode = '42501';
  end if;
  select * into v_cita from public."Citas" where id = p_cita_id for update;
  if not found then raise exception 'No se encontró la cita.' using errcode = 'P0002'; end if;
  if v_cita."Estado" = 'Completada' then
    raise exception 'Una cita completada no se puede cancelar; las horas del pack ya se consumieron.' using errcode = '22023';
  end if;
  if v_cita."Estado" not in ('Cancelada', 'Completada') and v_cita."Pack_id" is not null then
    update public."Packs"
      set "Horas_disponibles" = coalesce("Horas_disponibles", 0) + coalesce(v_cita."Duracion_horas", 3),
          "Estado" = case
            when "Estado" = 'Agotado' and ("Fecha_caducidad" is null or "Fecha_caducidad" >= current_date) then 'Activo'
            else "Estado"
          end
      where id = v_cita."Pack_id";
  end if;
  update public."Citas" set "Estado" = 'Cancelada' where id = p_cita_id;
  return p_cita_id;
end;
$$;

create or replace function public.eliminar_cita_con_pack(p_cita_id bigint)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cita public."Citas"%rowtype;
begin
  if not public.es_administrador() then
    raise exception 'No tienes permiso para gestionar citas y packs.' using errcode = '42501';
  end if;
  select * into v_cita from public."Citas" where id = p_cita_id for update;
  if not found then raise exception 'No se encontró la cita.' using errcode = 'P0002'; end if;
  if v_cita."Estado" not in ('Cancelada', 'Completada') and v_cita."Pack_id" is not null then
    update public."Packs"
      set "Horas_disponibles" = coalesce("Horas_disponibles", 0) + coalesce(v_cita."Duracion_horas", 3),
          "Estado" = case
            when "Estado" = 'Agotado' and ("Fecha_caducidad" is null or "Fecha_caducidad" >= current_date) then 'Activo'
            else "Estado"
          end
      where id = v_cita."Pack_id";
  end if;
  delete from public."Citas" where id = p_cita_id;
  return p_cita_id;
end;
$$;

revoke all on function public.guardar_cita_con_pack(bigint,bigint,bigint,timestamptz,text,numeric,numeric,text,text,text) from public, anon;
revoke all on function public.cancelar_cita_con_pack(bigint) from public, anon;
revoke all on function public.eliminar_cita_con_pack(bigint) from public, anon;
grant execute on function public.guardar_cita_con_pack(bigint,bigint,bigint,timestamptz,text,numeric,numeric,text,text,text) to authenticated;
grant execute on function public.cancelar_cita_con_pack(bigint) to authenticated;
grant execute on function public.eliminar_cita_con_pack(bigint) to authenticated;

notify pgrst, 'reload schema';

commit;
