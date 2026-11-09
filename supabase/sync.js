/* Cloud workspace snapshots. Loaded after the app and Supabase Auth scripts. */
(()=>{
  const client=window.lifeOsSupabase;
  if(!client)return;

  const blankState=()=>({tasks:[],events:[],habits:[],goals:[],projects:[],notes:[],inbox:[],transactions:[],budgets:[],expenses:0,budget:0});
  const clone=value=>JSON.parse(JSON.stringify(value));
  const stateKey=(userId,workspaceId)=>`lifeosCloudCache:${userId}:${workspaceId}`;
  let user=null,workspaces=[],activeWorkspace=null,version=null,ready=false,timer=null,busy=false,pending=false,conflicted=false,pendingGuestData=null,workspaceError='';
  const style=document.createElement('style');
  style.textContent='.workspace{width:calc(100% - 8px);text-align:left;background:var(--panel);font-family:inherit;cursor:pointer;transition:border-color .18s,background .18s}.workspace:hover{border-color:var(--green2);background:color-mix(in srgb,var(--panel) 80%,var(--green) 20%)}.ws-name,.ws-sub{display:block}.ws-name{max-width:150px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.ws-sub{margin-top:3px}.space-modal{max-width:470px;padding:26px}.space-list{display:grid;gap:9px;margin:16px 0}.space-choice{display:flex;justify-content:space-between;align-items:center;text-align:left;width:100%;padding:14px;border:1px solid var(--line);border-radius:13px;background:var(--panel);color:var(--text);transition:border-color .18s,transform .18s}.space-choice:hover{border-color:var(--green2);transform:translateY(-1px)}.space-choice.active{border-color:var(--green2);background:color-mix(in srgb,var(--panel) 88%,var(--green) 12%)}.space-kind{color:var(--muted);font-size:11px}.space-status{font-size:11px;color:var(--muted);min-height:18px;line-height:1.5}.space-create{display:flex;gap:9px;margin-top:18px}.space-create input{min-width:0;flex:1;background:var(--bg);border:1px solid var(--line);border-radius:10px;color:var(--text);padding:10px 12px;font-size:12px;outline:none}.space-create input:focus{border-color:var(--green2)}.profile{cursor:pointer;border-radius:12px;transition:background .18s}.profile:hover{background:var(--panel)}.account-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px}.account-email{font-size:16px;font-weight:700;overflow-wrap:anywhere}.account-id{font-size:11px;color:var(--muted);overflow-wrap:anywhere}.theme-options{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:10px;margin-top:14px}.theme-option{display:grid;justify-items:start;gap:10px;padding:12px;border:1px solid var(--line);border-radius:12px;background:var(--bg);color:var(--text);font-size:11px;transition:border-color .18s,transform .18s}.theme-option:hover{transform:translateY(-2px);border-color:var(--green2)}.theme-option.active{border-color:var(--green2);box-shadow:0 0 0 1px var(--green2)}.theme-preview{width:100%;height:42px;border-radius:8px;border:1px solid var(--line)}.theme-preview.dark{background:linear-gradient(135deg,#101210 50%,#c7ef83 50%)}.theme-preview.light{background:linear-gradient(135deg,#f7f8f4 50%,#83a956 50%)}.theme-preview.purple{background:linear-gradient(135deg,#110e18 50%,#d0b3ff 50%)}@media(max-width:720px){.account-grid{grid-template-columns:1fr}.theme-options{grid-template-columns:1fr}}';
  document.head.append(style);
  const spaceButton=document.querySelector('#spaceButton');
  const cacheLocal=(wid)=>{if(user&&wid)localStorage.setItem(stateKey(user.id,wid),JSON.stringify(data))};
  const setState=value=>{data={...blankState(),...(value&&typeof value==='object'?value:{})};localStorage.lifeosData=JSON.stringify(data);render()};
  function status(text){const el=document.querySelector('#spaceStatus');if(el)el.textContent=text}
  function showSpacePicker(message=''){
    const rows=workspaces.map(w=>`<button type="button" class="space-choice ${w.id===activeWorkspace?.id?'active':''}" data-space="${esc(w.id)}"><span><b>${esc(w.name)}</b><span class="space-kind">${w.kind==='personal'?'Личное пространство':'Общее пространство'}</span></span><span aria-hidden="true">${w.id===activeWorkspace?.id?'✓':'→'}</span></button>`).join('');
    document.querySelector('#overlay').innerHTML=`<div class="modal-backdrop" id="spaceBackdrop"><section class="modal space-modal"><h2>Пространства</h2><div class="space-status" id="spaceStatus">${esc(message||workspaceError||'Личное пространство видно только тебе. Общим можно пользоваться вместе с командой.')}</div><div class="space-list">${rows||'<div class="empty">Пока нет доступных пространств.<br>Обнови список или создай общее.</div>'}</div><form class="space-create" id="spaceCreate"><input name="name" placeholder="Например, Команда LIFE OS" maxlength="60" required><button class="primary">Создать общее</button></form><div class="modal-actions"><button type="button" class="secondary" id="refreshSpaces">Обновить список</button><button type="button" class="secondary" id="closeSpaces">Закрыть</button></div></section></div>`;
    const close=()=>document.querySelector('#overlay').innerHTML='';
    document.querySelector('#closeSpaces').onclick=close;
    document.querySelector('#refreshSpaces').onclick=async()=>{status('Проверяю доступные пространства…');await loadWorkspaces(true)};
    document.querySelector('#spaceBackdrop').onclick=e=>{if(e.target.id==='spaceBackdrop')close()};
    document.querySelectorAll('[data-space]').forEach(btn=>btn.onclick=async()=>{const target=workspaces.find(w=>w.id===btn.dataset.space);if(target){close();await switchWorkspace(target)}});
    document.querySelector('#spaceCreate').onsubmit=async e=>{e.preventDefault();const name=new FormData(e.currentTarget).get('name').trim();const submit=e.currentTarget.querySelector('button');submit.disabled=true;status('Создаём…');const {data:created,error}=await client.from('workspaces').insert({name,owner_id:user.id,kind:'shared'}).select('id,name,kind').single();submit.disabled=false;if(error){status(error.message);return}workspaces.push(created);close();await switchWorkspace(created);toast('Общее пространство создано')};
  }
  async function switchWorkspace(workspace){
    if(activeWorkspace?.id===workspace.id&&ready)return;
    if(timer){clearTimeout(timer);timer=null}
    if(activeWorkspace&&ready)await writeCloud();
    ready=false;busy=false;pending=false;conflicted=false;activeWorkspace=workspace;version=null;
    localStorage.setItem(`lifeosActiveSpace:${user.id}`,workspace.id);
    spaceButton.querySelector('.ws-name').textContent=workspace.name;
    spaceButton.querySelector('.ws-sub').textContent=workspace.kind==='personal'?'Личное пространство':'Общее пространство';
    spaceButton.title='Переключить пространство';
    const {data:row,error}=await client.from('workspace_app_state').select('payload,updated_at').eq('workspace_id',workspace.id).maybeSingle();
    if(error){activeWorkspace=null;toast('Не удалось загрузить пространство: '+error.message);return}
    if(row){version=row.updated_at;setState(row.payload);cacheLocal(workspace.id);toast('Облачные данные загружены')}
    else{
      const localRaw=workspace.kind==='personal'?pendingGuestData:null;
      const hasLocal=!!localRaw;
      const moveLocal=workspace.kind==='personal'&&hasLocal&&confirm('В личном пространстве пока нет облачных данных. Перенести сюда записи из этого браузера? При отказе они останутся в браузере и в облако не отправятся.');
      if(moveLocal){localStorage.setItem(stateKey(user.id,workspace.id),localRaw);pendingGuestData=null;}
      const cached=moveLocal?JSON.parse(localStorage.getItem(stateKey(user.id,workspace.id))||'null'):null;
      setState(cached||blankState());ready=true;await writeCloud();
      if(!moveLocal&&hasLocal)toast('Личные записи остались в этом браузере');
    }
    ready=true;
  }
  async function writeCloud(){
    if(!activeWorkspace||!user||!ready||conflicted)return;
    if(busy){pending=true;return}
    busy=true;pending=false;
    try{
      const payload=clone(data),updatedAt=new Date().toISOString();
      if(version){
        const {data:rows,error}=await client.from('workspace_app_state').update({payload,updated_by:user.id,updated_at:updatedAt}).eq('workspace_id',activeWorkspace.id).eq('updated_at',version).select('updated_at');
        if(error)throw error;
        if(!rows?.length){conflicted=true;throw new Error('Данные изменились в другом окне. Обнови страницу, чтобы загрузить актуальную версию.')}
        version=rows?.[0]?.updated_at||updatedAt;
      }else{
        const {data:row,error}=await client.from('workspace_app_state').insert({workspace_id:activeWorkspace.id,payload,updated_by:user.id,updated_at:updatedAt}).select('updated_at').single();
        if(error)throw error;version=row.updated_at;
      }
      cacheLocal(activeWorkspace.id);
    }catch(err){toast('Синхронизация не прошла: '+(err.message||'ошибка'));}
    finally{busy=false;if(pending){pending=false;scheduleWrite()}}
  }
  function scheduleWrite(){if(!ready||!activeWorkspace)return;cacheLocal(activeWorkspace.id);if(timer)clearTimeout(timer);timer=setTimeout(()=>{timer=null;writeCloud()},700)}
  const originalSave=save;
  save=function(){originalSave();scheduleWrite()};
  async function onAuthChange(next){
    const nextUser=next?.user||null;
    if(nextUser?.id===user?.id)return;
    if(user&&activeWorkspace&&ready){if(timer){clearTimeout(timer);timer=null}await writeCloud()}
    ready=false;activeWorkspace=null;workspaces=[];version=null;
    if(!user&&nextUser){pendingGuestData=localStorage.getItem('lifeosData');if(pendingGuestData)localStorage.setItem('lifeosGuestData',pendingGuestData)}
    user=nextUser;
    refreshProfileCard();
    if(!user){const guest=localStorage.getItem('lifeosGuestData');if(guest){try{data=JSON.parse(guest);localStorage.lifeosData=guest;render()}catch{setState(blankState())}}else setState(blankState());pendingGuestData=null;return}
    setState(blankState());
    await loadWorkspaces(false);
  }
  async function loadWorkspaces(refresh){
    const {data:rows,error}=await client.from('workspaces').select('id,name,kind').order('created_at');
    if(error){const msg='Не удалось загрузить пространства: '+error.message;workspaceError=msg;toast(msg);status(msg);return}
    workspaces=rows||[];
    if(!workspaces.length){
      const {error:ensureError}=await client.rpc('ensure_my_personal_workspace');
      if(ensureError){const msg='Не удалось создать личное пространство: '+ensureError.message;workspaceError=msg;toast(msg);status(msg);return}
      const {data:created,error:reloadError}=await client.from('workspaces').select('id,name,kind').order('created_at');
      if(reloadError){const msg='Не удалось перечитать пространства: '+reloadError.message;workspaceError=msg;toast(msg);status(msg);return}
      workspaces=created||[];
    }
    if(!workspaces.length){toast('Не получилось создать личное пространство');return}
    if(refresh){showSpacePicker('Список обновлён.');return}
    const preferred=localStorage.getItem(`lifeosActiveSpace:${user.id}`),workspace=workspaces.find(w=>w.id===preferred)||workspaces.find(w=>w.kind==='personal')||workspaces[0];
    await switchWorkspace(workspace);
  }
  spaceButton.onclick=()=>{if(!user){toast('Войди в аккаунт, чтобы управлять пространствами');return}showSpacePicker()};
  const brand=document.querySelector('.brand');
  if(brand){brand.setAttribute('role','button');brand.setAttribute('tabindex','0');brand.title='На главную';brand.style.cursor='pointer';brand.addEventListener('click',()=>{page='overview';render()});brand.addEventListener('keydown',e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();page='overview';render()}})}
  document.addEventListener('click',e=>{const overview=e.target.closest('[data-page="overview"]');if(!overview)return;e.preventDefault();e.stopImmediatePropagation();page='overview';render()},true);
  const profileCard=document.querySelector('.sidebar-bottom .profile');
  if(profileCard){profileCard.setAttribute('role','button');profileCard.setAttribute('tabindex','0');profileCard.setAttribute('aria-label','Открыть мой аккаунт');profileCard.addEventListener('click',()=>{page='account';render()});profileCard.addEventListener('keydown',e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();page='account';render()}})}
  const refreshProfileCard=()=>{const name=document.querySelector('#profileName'),email=document.querySelector('#profileEmail'),avatar=document.querySelector('.sidebar-bottom .avatar'),currentUser=window.lifeOsAuthSession?.user,label=localStorage.lifeosName||currentUser?.user_metadata?.display_name||currentUser?.email?.split('@')[0]||'Пользователь';if(name)name.textContent=label;if(email)email.textContent=currentUser?.email||'Нажми, чтобы открыть аккаунт';if(avatar)avatar.textContent=label.trim().slice(0,1).toUpperCase()||'L'};
  refreshProfileCard();
  document.addEventListener('click',async e=>{
    const theme=e.target.closest('[data-theme]');
    if(theme){e.preventDefault();e.stopImmediatePropagation();localStorage.lifeosTheme=theme.dataset.theme;render();toast(({dark:'Тёмная тема',light:'Светлая тема',purple:'Фиолетовая тема'})[theme.dataset.theme]);return}
    if(e.target.closest('#saveAccount')){e.preventDefault();e.stopImmediatePropagation();const name=document.querySelector('#accountName')?.value.trim()||'Пользователь';localStorage.lifeosName=name;let error=null;if(user){({error}=await client.auth.updateUser({data:{display_name:name}}))}refreshProfileCard();render();toast(error?'Имя сохранено на этом устройстве':'Профиль сохранён');return}
    if(e.target.closest('#accountAuthAction')){e.preventDefault();e.stopImmediatePropagation();if(user){const {error}=await client.auth.signOut();if(error)toast('Не удалось выйти: '+error.message)}else document.querySelector('#authButton')?.click()}
  },true);
  window.addEventListener('lifeos-auth-change',e=>onAuthChange(e.detail?.session));
  if(window.lifeOsAuthSession)onAuthChange(window.lifeOsAuthSession);
})();
