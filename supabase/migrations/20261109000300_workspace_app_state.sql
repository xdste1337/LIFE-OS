-- Browser app snapshot storage. Workspace membership and RLS control access.
create table public.workspace_app_state (
  workspace_id uuid primary key references public.workspaces(id) on delete cascade,
  payload jsonb not null default '{}'::jsonb,
  updated_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now()
);

alter table public.workspace_app_state enable row level security;

create policy "app_state_read_workspace"
  on public.workspace_app_state for select
  using (public.has_workspace_role(workspace_id));

create policy "app_state_create_editors"
  on public.workspace_app_state for insert
  with check (
    public.has_workspace_role(workspace_id, array['owner','admin','editor'])
    and updated_by = auth.uid()
  );

create policy "app_state_update_editors"
  on public.workspace_app_state for update
  using (public.has_workspace_role(workspace_id, array['owner','admin','editor']))
  with check (
    public.has_workspace_role(workspace_id, array['owner','admin','editor'])
    and updated_by = auth.uid()
  );

grant select, insert, update on public.workspace_app_state to authenticated;
revoke all on public.workspace_app_state from anon;
