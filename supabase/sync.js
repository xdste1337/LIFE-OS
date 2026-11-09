/* Cloud workspace snapshots. Loaded after the app and Supabase Auth scripts. */
(()=>{
  const client=window.lifeOsSupabase;
  if(!client)return;

  const blankState=()=>({tasks:[],events:[],habits:[],goals:[],projects:[],notes:[],inbox:[],transactions:[],budgets:[],expenses:0,budget:0});
  const clone=value=>JSON.parse(JSON.stringify(value));
  const stateKey=(userId,workspaceId)=>`lifeosCloudCache:${userId}:${workspaceId}`;
  let user=null,workspaces=[],activeWorkspace=null,version=null,ready=false,timer=null,busy=false,pending=false,conflicted=false,pendingGuestData=null;
  const style=document.createElement('style');
  style.textContent='.workspace{width:calc(100% - 8px);text-align:left;background:transparent;font-family:inherit;cursor:pointer}.workspace:hover{border-color:var(--green2)}.space-modal{max-width:440px}.space-list{display:grid;gap:8px;margin:16px 0}.space-choice{display:flex;justify-content:space-between;align-items:center;text-align:left;width:100%;padding:12px;border:1px solid var(--line);border-radius:12px;background:var(--surface);color:var(--text)}.space-choice.active{border-color:var(--green2)}.space-kind{color:var(--muted);font-size:11px}.space-status{font-size:11px;color:var(--muted);min-height:18px}.space-create{display:flex;gap:8px;margin-top:14px}.space-create input{min-width:0;flex:1}';
  document.head.append(style);
  const spaceButton=document.querySelector('#spaceButton');
  const cacheLocal=(wid)=>{if(user&&wid)localStorage.setItem(stateKey(user.id,wid),JSON.stringify(data))};
  const setState=value=>{data={...blankState(),...(value&&typeof value==='object'?value:{})};localStorage.lifeosData=JSON.stringify(data);render()};
  function status(text){const el=document.querySelector('#spaceStatus');if(el)el.textContent=text}
  function showSpacePicker(message=''){
    const rows=workspaces.map(w=>`<button type="button" class="space-choice ${w.id===activeWorkspace?.id?'active':''}" data-space="${esc(w.id)}"><span>${esc(w.name)}</span><span class="space-kind">${w.kind==='personal'?'Личное':'Общее'}</span></button>`).join('');
    document.querySelector('#overlay').innerHTML=`<div class="modal-backdrop" id="spaceBackdrop"><section class="modal space-modal"><h2>Ваши пространства</h2><div class="space-status" id="spaceStatus">${esc(message)}</div><div class="space-list">${rows||'<div class="empty">Пространства не найдены</div>'}</div><form class="space-create" id="spaceCreate"><input name="name" placeholder="Название общего пространства" maxlength="60" required><button class="primary">Создать</button></form><div class="modal-actions"><button type="button" class="secondary" id="closeSpaces">Закрыть</button></div></section></div>`;
    const close=()=>document.querySelector('#overlay').innerHTML='';
    document.querySelector('#closeSpaces').onclick=close;
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
    if(!user){const guest=localStorage.getItem('lifeosGuestData');if(guest){try{data=JSON.parse(guest);localStorage.lifeosData=guest;render()}catch{setState(blankState())}}else setState(blankState());pendingGuestData=null;return}
    setState(blankState());
    const {data:rows,error}=await client.from('workspaces').select('id,name,kind').order('created_at');
    if(error){toast('Не удалось получить список пространств: '+error.message);return}
    workspaces=rows||[];
    if(!workspaces.length){toast('Для аккаунта не найдено личное пространство');return}
    const preferred=localStorage.getItem(`lifeosActiveSpace:${user.id}`),workspace=workspaces.find(w=>w.id===preferred)||workspaces.find(w=>w.kind==='personal')||workspaces[0];
    await switchWorkspace(workspace);
  }
  spaceButton.onclick=()=>{if(!user){toast('Войди в аккаунт, чтобы управлять пространствами');return}showSpacePicker()};
  const brand=document.querySelector('.brand');
  if(brand){brand.setAttribute('role','button');brand.setAttribute('tabindex','0');brand.title='На главную';brand.style.cursor='pointer';brand.addEventListener('click',()=>{page='overview';render()});brand.addEventListener('keydown',e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();page='overview';render()}})}
  document.addEventListener('click',e=>{const overview=e.target.closest('[data-page="overview"]');if(!overview)return;e.preventDefault();e.stopImmediatePropagation();page='overview';render()},true);
  window.addEventListener('lifeos-auth-change',e=>onAuthChange(e.detail?.session));
  if(window.lifeOsAuthSession)onAuthChange(window.lifeOsAuthSession);
})();
