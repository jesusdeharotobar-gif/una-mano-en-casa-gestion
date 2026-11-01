-- Crea un movimiento pendiente automáticamente al registrar una compra de pack
-- o una cita facturable sin canje de pack. No crea cargos retroactivos.
-- Requiere public.es_administrador() y las tablas Citas, Packs, Cobros, Clientes.
begin;

alter table public."Cobros"
  add column if not exists "Cita_id" bigint;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public."Cobros"'::regclass
      and conname = 'Cobros_Cita_id_fkey'
  ) then
    alter table public."Cobros"
      add constraint "Cobros_Cita_id_fkey"
      foreign key ("Cita_id") references public."Citas" (id)
      on delete set null;
  end if;
end;
$$;

create unique index if not exists "Cobros_Cita_id_unique"
  on public."Cobros" ("Cita_id") where "Cita_id" is not null;

create or replace function public.crear_cobro_pendiente_de_cita()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.es_administrador() then
    raise exception 'No tienes permiso para gestionar cobros.' using errcode = '42501';
  end if;

  if new."Pack_id" is not null or new."Estado" = 'Cancelada'
     or coalesce(new."Precio", 0) <= 0 then
    update public."Cobros"
      set "Estado" = 'Anulado'
      where "Cita_id" = new.id and "Estado" = 'Pendiente';
    return new;
  end if;

  insert into public."Cobros" as charge
    ("Cliente_id", "Cita_id", "Importe", "Método_pago", "Fecha_cobro", "Estado")
  values
    (new."Cliente_id", new.id, new."Precio", new."Método de pago", now(), 'Pendiente')
  on conflict ("Cita_id") where "Cita_id" is not null
  do update set
    "Cliente_id" = excluded."Cliente_id",
    "Importe" = excluded."Importe",
    "Método_pago" = excluded."Método_pago"
  where charge."Estado" in ('Pendiente', 'Anulado');

  return new;
end;
$$;

create or replace function public.anular_cobro_pendiente_antes_de_borrar_cita()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.es_administrador() then
    raise exception 'No tienes permiso para gestionar cobros.' using errcode = '42501';
  end if;
  update public."Cobros"
    set "Estado" = 'Anulado'
    where "Cita_id" = old.id and "Estado" = 'Pendiente';
  return old;
end;
$$;

create or replace function public.crear_cobro_pendiente_de_pack()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.es_administrador() then
    raise exception 'No tienes permiso para gestionar cobros.' using errcode = '42501';
  end if;
  if coalesce(new."Precio_pagado", 0) > 0 and coalesce(new."Estado", '') <> 'Anulado' then
    insert into public."Cobros"
      ("Cliente_id", "Pack_id", "Importe", "Fecha_cobro", "Estado")
    values
      (new."Cliente_id", new.id, new."Precio_pagado", now(), 'Pendiente');
  end if;
  return new;
end;
$$;

drop trigger if exists "Citas_crear_cobro_pendiente" on public."Citas";
create trigger "Citas_crear_cobro_pendiente"
  after insert or update on public."Citas"
  for each row execute function public.crear_cobro_pendiente_de_cita();

drop trigger if exists "Citas_anular_cobro_antes_de_borrar" on public."Citas";
create trigger "Citas_anular_cobro_antes_de_borrar"
  before delete on public."Citas"
  for each row execute function public.anular_cobro_pendiente_antes_de_borrar_cita();

drop trigger if exists "Packs_crear_cobro_pendiente" on public."Packs";
create trigger "Packs_crear_cobro_pendiente"
  after insert on public."Packs"
  for each row execute function public.crear_cobro_pendiente_de_pack();

-- Recupera packs ya registrados que todavía no tienen movimiento vinculado.
-- El NOT EXISTS hace que se pueda volver a ejecutar sin duplicarlos.
insert into public."Cobros"
  ("Cliente_id", "Pack_id", "Importe", "Fecha_cobro", "Estado")
select p."Cliente_id", p.id, p."Precio_pagado", coalesce(p.created_at, now()), 'Pendiente'
from public."Packs" p
where coalesce(p."Precio_pagado", 0) > 0
  and coalesce(p."Estado", '') <> 'Anulado'
  and not exists (
    select 1 from public."Cobros" c where c."Pack_id" = p.id
  );

revoke all on function public.crear_cobro_pendiente_de_cita() from public, anon, authenticated;
revoke all on function public.anular_cobro_pendiente_antes_de_borrar_cita() from public, anon, authenticated;
revoke all on function public.crear_cobro_pendiente_de_pack() from public, anon, authenticated;

notify pgrst, 'reload schema';
commit;
