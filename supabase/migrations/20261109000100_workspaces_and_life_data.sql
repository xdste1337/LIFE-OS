-- LIFE OS foundations: private personal spaces and explicitly shared spaces.
-- Run this migration in the Supabase project before connecting the web client.

create extension if not exists pgcrypto;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.user_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  theme text not null default 'dark' check (theme in ('dark', 'light', 'purple')),
  language text not null default 'ru',
  default_currency text not null default 'RUB',
  timezone text not null default 'Europe/Moscow',
  dashboard_layout jsonb not null default '{}'::jsonb,
  notification_settings jsonb not null default '{}'::jsonb
);

create table public.workspaces (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  owner_id uuid not null references auth.users(id) on delete restrict,
  kind text not null check (kind in ('personal', 'shared')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index workspaces_one_personal_per_owner
  on public.workspaces(owner_id) where kind = 'personal';

create table public.workspace_members (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner', 'admin', 'editor', 'viewer')),
  joined_at timestamptz not null default now(),
  primary key (workspace_id, user_id)
);

create table public.workspace_invites (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  email text not null,
  role text not null check (role in ('admin', 'editor', 'viewer')),
  token_hash text not null unique,
  invited_by uuid not null references auth.users(id),
  expires_at timestamptz not null,
  accepted_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index workspace_invites_pending_email
  on public.workspace_invites (workspace_id, lower(email))
  where accepted_at is null;

create or replace function public.accept_workspace_invite(p_token_hash text)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  invitation public.workspace_invites%rowtype;
  account_email text;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required';
  end if;

  select email into account_email from auth.users where id = auth.uid();
  select * into invitation
  from public.workspace_invites
  where token_hash = p_token_hash
    and lower(email) = lower(coalesce(account_email, ''))
    and accepted_at is null
    and expires_at > now()
  for update;

  if invitation.id is null then
    raise exception 'Invitation is invalid, expired, or addressed to another account';
  end if;

  insert into public.workspace_members (workspace_id, user_id, role)
  values (invitation.workspace_id, auth.uid(), invitation.role)
  on conflict (workspace_id, user_id) do nothing;

  update public.workspace_invites
  set accepted_at = now()
  where id = invitation.id;

  return invitation.workspace_id;
end;
$$;
revoke all on function public.accept_workspace_invite(text) from public;
grant execute on function public.accept_workspace_invite(text) to authenticated;

create or replace function public.has_workspace_role(
  p_workspace_id uuid,
  p_roles text[] default array['owner', 'admin', 'editor', 'viewer']::text[]
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.workspace_members wm
    where wm.workspace_id = p_workspace_id
      and wm.user_id = auth.uid()
      and wm.role = any (p_roles)
  );
$$;

create or replace function public.add_workspace_owner()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.workspace_members (workspace_id, user_id, role)
  values (new.id, new.owner_id, 'owner')
  on conflict (workspace_id, user_id) do nothing;
  return new;
end;
$$;

create trigger workspace_owner_membership
  after insert on public.workspaces
  for each row execute function public.add_workspace_owner();

create or replace function public.bootstrap_life_os_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  personal_workspace_id uuid;
  profile_name text;
begin
  profile_name := coalesce(
    nullif(new.raw_user_meta_data ->> 'display_name', ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    'Пользователь'
  );

  insert into public.profiles (id, display_name)
  values (new.id, profile_name)
  on conflict (id) do nothing;

  insert into public.user_settings (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  select id into personal_workspace_id
  from public.workspaces
  where owner_id = new.id and kind = 'personal';

  if personal_workspace_id is null then
    insert into public.workspaces (name, owner_id, kind)
    values ('Личное пространство', new.id, 'personal')
    returning id into personal_workspace_id;
  end if;

  return new;
end;
$$;

create trigger on_auth_user_created_life_os
  after insert on auth.users
  for each row execute function public.bootstrap_life_os_user();

-- Add personal spaces for accounts which existed before this migration.
do $$
declare
  existing_user record;
begin
  for existing_user in select id, email, raw_user_meta_data from auth.users loop
    insert into public.profiles (id, display_name)
    values (
      existing_user.id,
      coalesce(
        nullif(existing_user.raw_user_meta_data ->> 'display_name', ''),
        nullif(split_part(coalesce(existing_user.email, ''), '@', 1), ''),
        'Пользователь'
      )
    ) on conflict (id) do nothing;

    insert into public.user_settings (user_id)
    values (existing_user.id)
    on conflict (user_id) do nothing;

    if not exists (
      select 1 from public.workspaces
      where owner_id = existing_user.id and kind = 'personal'
    ) then
      insert into public.workspaces (name, owner_id, kind)
      values ('Личное пространство', existing_user.id, 'personal');
    end if;
  end loop;
end;
$$;

create or replace function public.prevent_workspace_owner_change()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.owner_id is distinct from old.owner_id then
    raise exception 'Workspace ownership changes must use the transfer flow';
  end if;
  return new;
end;
$$;

create trigger workspace_owner_immutable
  before update of owner_id on public.workspaces
  for each row execute function public.prevent_workspace_owner_change();

create table public.projects (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  created_by uuid not null references auth.users(id),
  name text not null,
  description text not null default '',
  status text not null default 'planned'
    check (status in ('planned', 'active', 'on_hold', 'completed', 'archived')),
  priority text not null default 'medium'
    check (priority in ('low', 'medium', 'high', 'critical')),
  starts_at date,
  deadline date,
  progress integer not null default 0 check (progress between 0 and 100),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  created_by uuid not null references auth.users(id),
  assignee_id uuid references auth.users(id) on delete set null,
  project_id uuid references public.projects(id) on delete set null,
  title text not null,
  description text not null default '',
  status text not null default 'todo'
    check (status in ('backlog', 'todo', 'in_progress', 'done', 'cancelled')),
  priority text not null default 'medium'
    check (priority in ('low', 'medium', 'high', 'critical')),
  due_at timestamptz,
  recurrence_rule text,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.calendar_events (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  created_by uuid not null references auth.users(id),
  task_id uuid references public.tasks(id) on delete set null,
  title text not null,
  description text not null default '',
  starts_at timestamptz not null,
  ends_at timestamptz,
  timezone text not null default 'Europe/Moscow',
  location text,
  recurrence_rule text,
  reminder_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at is null or ends_at >= starts_at)
);

create table public.finance_accounts (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  name text not null,
  kind text not null default 'cash'
    check (kind in ('cash', 'bank_card', 'savings', 'other')),
  currency text not null default 'RUB' check (currency ~ '^[A-Z]{3}$'),
  opening_balance numeric(14,2) not null default 0,
  created_at timestamptz not null default now()
);

create table public.finance_categories (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  parent_id uuid references public.finance_categories(id) on delete set null,
  name text not null,
  kind text not null default 'expense' check (kind in ('income', 'expense', 'both')),
  created_at timestamptz not null default now(),
  unique (workspace_id, parent_id, name)
);

create table public.transactions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  created_by uuid not null references auth.users(id),
  account_id uuid references public.finance_accounts(id) on delete set null,
  category_id uuid references public.finance_categories(id) on delete set null,
  kind text not null check (kind in ('income', 'expense', 'transfer', 'refund')),
  amount numeric(14,2) not null check (amount >= 0),
  currency text not null default 'RUB' check (currency ~ '^[A-Z]{3}$'),
  description text not null default '',
  occurred_at timestamptz not null default now(),
  recurrence_rule text,
  import_fingerprint text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.budgets (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  category_id uuid references public.finance_categories(id) on delete cascade,
  month date not null,
  currency text not null default 'RUB' check (currency ~ '^[A-Z]{3}$'),
  limit_amount numeric(14,2) not null check (limit_amount > 0),
  created_at timestamptz not null default now()
);
create unique index budgets_category_unique
  on public.budgets (workspace_id, category_id, month, currency)
  where category_id is not null;
create unique index budgets_global_unique
  on public.budgets (workspace_id, month, currency)
  where category_id is null;

create table public.habits (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  created_by uuid not null references auth.users(id),
  name text not null,
  description text not null default '',
  target_value numeric(12,2) not null default 1 check (target_value > 0),
  unit text not null default 'раз',
  schedule jsonb not null default '{"frequency":"daily"}'::jsonb,
  reminder_at time,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.habit_logs (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  habit_id uuid not null references public.habits(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  value numeric(12,2) not null default 1 check (value >= 0),
  logged_on date not null default current_date,
  note text not null default '',
  created_at timestamptz not null default now(),
  unique (habit_id, user_id, logged_on)
);

create table public.goals (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  created_by uuid not null references auth.users(id),
  name text not null,
  description text not null default '',
  category text not null default 'personal',
  target_value numeric(14,2),
  current_value numeric(14,2) not null default 0,
  unit text not null default '',
  starts_on date,
  deadline date,
  status text not null default 'active'
    check (status in ('active', 'completed', 'on_hold', 'cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.goal_milestones (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  goal_id uuid not null references public.goals(id) on delete cascade,
  title text not null,
  completed_at timestamptz,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

create table public.notes (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  created_by uuid not null references auth.users(id),
  title text not null,
  body text not null default '',
  folder text,
  tags text[] not null default '{}',
  is_favorite boolean not null default false,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.inbox_items (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  created_by uuid not null references auth.users(id),
  content text not null,
  item_type text not null default 'other'
    check (item_type in ('task', 'note', 'event', 'expense', 'idea', 'purchase', 'other')),
  processed_at timestamptz,
  created_at timestamptz not null default now()
);

create index tasks_workspace_due_idx on public.tasks (workspace_id, due_at);
create index projects_workspace_status_idx on public.projects (workspace_id, status);
create index calendar_workspace_start_idx on public.calendar_events (workspace_id, starts_at);
create index transactions_workspace_occurred_idx on public.transactions (workspace_id, occurred_at desc);
create index habits_workspace_idx on public.habits (workspace_id);
create index goals_workspace_idx on public.goals (workspace_id, status);
create index notes_workspace_updated_idx on public.notes (workspace_id, updated_at desc);
create index inbox_workspace_created_idx on public.inbox_items (workspace_id, created_at desc);

-- Prevent links between rows belonging to different workspaces.
create or replace function public.assert_workspace_links()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  linked_workspace_id uuid;
  has_link boolean := false;
begin
  if tg_table_name = 'tasks' and new.project_id is not null then
    has_link := true;
    select workspace_id into linked_workspace_id from public.projects where id = new.project_id;
  elsif tg_table_name = 'calendar_events' and new.task_id is not null then
    has_link := true;
    select workspace_id into linked_workspace_id from public.tasks where id = new.task_id;
  elsif tg_table_name = 'transactions' then
    if new.account_id is not null then
      select workspace_id into linked_workspace_id from public.finance_accounts where id = new.account_id;
      if linked_workspace_id is null or linked_workspace_id <> new.workspace_id then
        raise exception 'Related records must belong to the same workspace';
      end if;
    end if;
    if new.category_id is not null then
      select workspace_id into linked_workspace_id from public.finance_categories where id = new.category_id;
      if linked_workspace_id is null or linked_workspace_id <> new.workspace_id then
        raise exception 'Related records must belong to the same workspace';
      end if;
    end if;
    return new;
  elsif tg_table_name = 'budgets' and new.category_id is not null then
    has_link := true;
    select workspace_id into linked_workspace_id from public.finance_categories where id = new.category_id;
  elsif tg_table_name = 'finance_categories' and new.parent_id is not null then
    has_link := true;
    select workspace_id into linked_workspace_id from public.finance_categories where id = new.parent_id;
  elsif tg_table_name = 'habit_logs' then
    has_link := true;
    select workspace_id into linked_workspace_id from public.habits where id = new.habit_id;
  elsif tg_table_name = 'goal_milestones' then
    has_link := true;
    select workspace_id into linked_workspace_id from public.goals where id = new.goal_id;
  end if;

  if has_link and (linked_workspace_id is null or linked_workspace_id <> new.workspace_id) then
    raise exception 'Related records must belong to the same workspace';
  end if;

  return new;
end;
$$;

create trigger tasks_project_same_workspace
  before insert or update of workspace_id, project_id on public.tasks
  for each row execute function public.assert_workspace_links();
create trigger calendar_task_same_workspace
  before insert or update of workspace_id, task_id on public.calendar_events
  for each row execute function public.assert_workspace_links();
create trigger transaction_account_same_workspace
  before insert or update of workspace_id, account_id on public.transactions
  for each row execute function public.assert_workspace_links();
create trigger budget_category_same_workspace
  before insert or update of workspace_id, category_id on public.budgets
  for each row execute function public.assert_workspace_links();
create trigger finance_category_parent_same_workspace
  before insert or update of workspace_id, parent_id on public.finance_categories
  for each row execute function public.assert_workspace_links();
create trigger habit_log_same_workspace
  before insert or update of workspace_id, habit_id on public.habit_logs
  for each row execute function public.assert_workspace_links();
create trigger milestone_goal_same_workspace
  before insert or update of workspace_id, goal_id on public.goal_milestones
  for each row execute function public.assert_workspace_links();

alter table public.profiles enable row level security;
create policy "profiles_read_self" on public.profiles
  for select using (id = auth.uid());
create policy "profiles_read_workspace_members" on public.profiles
  for select using (
    exists (
      select 1 from public.workspace_members wm
      where wm.user_id = profiles.id
        and public.has_workspace_role(wm.workspace_id)
    )
  );
create policy "profiles_update_self" on public.profiles
  for update using (id = auth.uid()) with check (id = auth.uid());

alter table public.user_settings enable row level security;
create policy "settings_read_self" on public.user_settings
  for select using (user_id = auth.uid());
create policy "settings_insert_self" on public.user_settings
  for insert with check (user_id = auth.uid());
create policy "settings_update_self" on public.user_settings
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());

alter table public.workspaces enable row level security;
create policy "workspaces_read_member" on public.workspaces
  for select using (public.has_workspace_role(id));
create policy "workspaces_create_shared" on public.workspaces
  for insert with check (owner_id = auth.uid() and kind = 'shared');
create policy "workspaces_update_admin" on public.workspaces
  for update using (public.has_workspace_role(id, array['owner','admin']))
  with check (public.has_workspace_role(id, array['owner','admin']));
create policy "workspaces_delete_owner" on public.workspaces
  for delete using (owner_id = auth.uid());

alter table public.workspace_members enable row level security;
create policy "members_read_workspace" on public.workspace_members
  for select using (public.has_workspace_role(workspace_id));
create policy "members_add_admin" on public.workspace_members
  for insert with check (
    public.has_workspace_role(workspace_id, array['owner','admin'])
    and role <> 'owner'
  );
create policy "members_update_admin" on public.workspace_members
  for update using (
    public.has_workspace_role(workspace_id, array['owner','admin']) and role <> 'owner'
  ) with check (
    public.has_workspace_role(workspace_id, array['owner','admin']) and role <> 'owner'
  );
create policy "members_remove_admin" on public.workspace_members
  for delete using (
    public.has_workspace_role(workspace_id, array['owner','admin'])
    and role <> 'owner'
  );

alter table public.workspace_invites enable row level security;
create policy "invites_read_admin" on public.workspace_invites
  for select using (public.has_workspace_role(workspace_id, array['owner','admin']));
create policy "invites_create_admin" on public.workspace_invites
  for insert with check (
    public.has_workspace_role(workspace_id, array['owner','admin'])
    and invited_by = auth.uid()
  );
create policy "invites_update_admin" on public.workspace_invites
  for update using (public.has_workspace_role(workspace_id, array['owner','admin']))
  with check (public.has_workspace_role(workspace_id, array['owner','admin']));
create policy "invites_remove_admin" on public.workspace_invites
  for delete using (public.has_workspace_role(workspace_id, array['owner','admin']));

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'projects', 'tasks', 'calendar_events', 'finance_accounts',
    'finance_categories', 'transactions', 'budgets', 'habits',
    'habit_logs', 'goals', 'goal_milestones', 'notes', 'inbox_items'
  ] loop
    execute format('alter table public.%I enable row level security', table_name);
    execute format(
      'create policy %I on public.%I for select using (public.has_workspace_role(workspace_id))',
      table_name || '_read_member', table_name
    );
    if table_name in ('projects', 'tasks', 'calendar_events', 'transactions', 'habits', 'goals', 'notes', 'inbox_items') then
      execute format(
        'create policy %I on public.%I for insert with check (public.has_workspace_role(workspace_id, array[''owner'',''admin'',''editor'']) and created_by = auth.uid())',
        table_name || '_insert_editor', table_name
      );
    elsif table_name = 'habit_logs' then
      execute format(
        'create policy %I on public.%I for insert with check (public.has_workspace_role(workspace_id, array[''owner'',''admin'',''editor'']) and user_id = auth.uid())',
        table_name || '_insert_editor', table_name
      );
    else
      execute format(
        'create policy %I on public.%I for insert with check (public.has_workspace_role(workspace_id, array[''owner'',''admin'',''editor'']))',
        table_name || '_insert_editor', table_name
      );
    end if;
    execute format(
      'create policy %I on public.%I for update using (public.has_workspace_role(workspace_id, array[''owner'',''admin'',''editor''])) with check (public.has_workspace_role(workspace_id, array[''owner'',''admin'',''editor'']))',
      table_name || '_update_editor', table_name
    );
    execute format(
      'create policy %I on public.%I for delete using (public.has_workspace_role(workspace_id, array[''owner'',''admin'',''editor'']))',
      table_name || '_delete_editor', table_name
    );
  end loop;
end;
$$;
