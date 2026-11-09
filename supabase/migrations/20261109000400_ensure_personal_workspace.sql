-- Repair a missing personal workspace for the currently signed-in user.
create or replace function public.ensure_my_personal_workspace()
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  workspace_id uuid;
  current_user_id uuid := auth.uid();
begin
  if current_user_id is null then
    raise exception 'Authentication is required';
  end if;

  insert into public.workspaces (name, owner_id, kind)
  values ('Личное пространство', current_user_id, 'personal')
  on conflict (owner_id) where kind = 'personal' do nothing;

  select id into workspace_id
  from public.workspaces
  where owner_id = current_user_id and kind = 'personal';

  insert into public.workspace_members (workspace_id, user_id, role)
  values (workspace_id, current_user_id, 'owner')
  on conflict (workspace_id, user_id) do update set role = 'owner';

  return workspace_id;
end;
$$;

revoke all on function public.ensure_my_personal_workspace() from public, anon;
grant execute on function public.ensure_my_personal_workspace() to authenticated;
