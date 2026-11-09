-- The Data API needs SQL grants in addition to RLS policies.
-- RLS remains the row-level boundary for every authenticated request.

grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;

-- Used by RLS policies. The function only answers for the current JWT user.
revoke all on function public.has_workspace_role(uuid, text[]) from public, anon;
grant execute on function public.has_workspace_role(uuid, text[]) to authenticated;

-- These are trigger-only functions; never expose them as callable API RPCs.
revoke all on function public.add_workspace_owner() from public, anon, authenticated;
revoke all on function public.bootstrap_life_os_user() from public, anon, authenticated;
revoke all on function public.prevent_workspace_owner_change() from public, anon, authenticated;
revoke all on function public.assert_workspace_links() from public, anon, authenticated;

revoke all on function public.accept_workspace_invite(text) from public, anon;
grant execute on function public.accept_workspace_invite(text) to authenticated;
