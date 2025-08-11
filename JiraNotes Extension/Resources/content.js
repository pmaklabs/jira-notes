 (function () {
   if (window.__jiraNotesInjected) return;
   window.__jiraNotesInjected = true;

   const PORT = 18427;

   const css = `
     #jira-notes-toggle {
       position: fixed;
       bottom: 16px;
       right: 16px;
       z-index: 2147483647;
       width: 32px;                /* equal width/height for circle */
       height: 32px;
       border-radius: 50%;         /* full circle */
       padding: 0;                 /* no extra padding */
       background: #fff;           /* white background */
       color: #000000;             /* Jira blue text */
       font: bold 14px system-ui, -apple-system, Segoe UI, Roboto, Arial, sans-serif;
       text-align: center;
       line-height: 32px;          /* vertically center the text */
       cursor: pointer;
       box-shadow: 0 2px 6px rgba(0,0,0,.15);
       border: 1px solid rgba(0,0,0,.1); /* subtle border */
     }
     #jira-notes-panel{position:fixed;bottom:64px;right:16px;width:360px;height:240px;background:#fff;border:1px solid rgba(0,0,0,.1);border-radius:10px;z-index:2147483647;display:none;box-shadow:0 10px 30px rgba(0,0,0,.2);overflow:hidden}
     #jira-notes-header{height:36px;background:#F4F5F7;display:flex;align-items:center;justify-content:space-between;padding:0 10px;border-bottom:1px solid #E1E2E6;user-select:none}
     #jira-notes-resize{width:14px;height:14px;border:2px solid #7A869A;border-right:none;border-bottom:none;transform:rotate(45deg);cursor:nwse-resize;margin-right:auto}
     #jira-notes-actions{display:flex;gap:8px}
     #jira-notes-choose,#jira-notes-export{background:transparent;border:none;color:#0052CC;cursor:pointer}
     #jira-notes-text{width:100%;height:calc(100% - 36px);border:none;outline:none;padding:10px;font:13px/1.4 system-ui, -apple-system, Segoe UI, Roboto, Arial, sans-serif;resize:none;box-sizing:border-box}
   `;
   const style = document.createElement('style'); style.textContent = css; document.documentElement.appendChild(style);

   const toggle = document.createElement('button'); toggle.id='jira-notes-toggle'; toggle.textContent='N';
   const panel = document.createElement('div'); panel.id='jira-notes-panel';
   panel.innerHTML = `
     <div id="jira-notes-header">
       <div id="jira-notes-resize" title="Resize"></div>
       <div style="font-weight:600;">Jira Notes</div>
       <div id="jira-notes-actions">
         <button id="jira-notes-choose" title="Choose notes directory">Choose Dir</button>
         <button id="jira-notes-export" title="Export JSON">Export</button>
       </div>
     </div>
     <textarea id="jira-notes-text" placeholder="Type notes for this ticket…"></textarea>
   `;
   document.documentElement.appendChild(toggle);
   document.documentElement.appendChild(panel);
   const textarea = panel.querySelector('#jira-notes-text');

   function getTicketId() {
     const m = location.pathname.match(/\/browse\/([A-Z0-9]+-\d+)/i);
     if (m) return m[1].toUpperCase();
     const p = new URLSearchParams(location.search).get('selectedIssue');
     return p ? p.toUpperCase() : null;
   }

     async function api(path, opts = {}) {
       const method = opts.method || "GET";
       const body = opts.body || null; // pass an object; background will JSON.stringify
       const res = await new Promise((resolve) => {
         chrome.runtime.sendMessage({ type: "jiraNotes.api", path, method, body }, resolve);
       });
       if (!res || !res.ok) throw new Error(res?.error || `HTTP ${res?.status || "0"}`);
       return res.payload;
     }
   async function ensureServer() { try { await api('/ping'); return true; } catch { return false; } }

   async function loadNote() {
     const tid = getTicketId(); if (!tid) return;
     try {
       const raw = await api(`/load?ticketId=${encodeURIComponent(tid)}`);
       const obj = typeof raw === 'string' ? JSON.parse(raw) : raw;
       textarea.value = obj.text || "";
     } catch (e) { console.warn('JiraNotes load failed', e); }
   }
   async function saveNote() {
     const tid = getTicketId(); if (!tid) return;
     const payload = { ticketId: tid, text: textarea.value, updatedAt: new Date().toISOString() };
     try { await api(`/save?ticketId=${encodeURIComponent(tid)}`, { method: 'POST', body: JSON.stringify(payload) }); }
     catch (e) { console.warn('JiraNotes save failed', e); }
   }

     // ensure highest priority click + logs
     toggle.addEventListener('click', async (e) => {
       try {
         e.preventDefault();
         e.stopPropagation();

         console.log("[JiraNotes] Note button clicked at", Date.now());

         // optional: show immediately; we'll update content after ping
         if (panel.style.display !== 'block') {
           panel.style.display = 'block';
         } else {
           panel.style.display = 'none';
           return;
         }

         // connection status dot
         let dot = panel.querySelector('#jira-notes-statusdot');
         if (!dot) {
           const header = panel.querySelector('#jira-notes-header');
           dot = document.createElement('div');
           dot.id = 'jira-notes-statusdot';
           dot.style.cssText = 'width:10px;height:10px;border-radius:50%;margin-left:8px;background:#aaa;';
           header.insertBefore(dot, header.firstChild);
         }

         // ping via background
         let ok = false;
         try {
           const res = await chrome.runtime.sendMessage({ type: "jiraNotes.api", path: "/ping", method: "GET" });
           ok = !!(res && res.ok);
         } catch {}
         dot.style.background = ok ? '#2ecc71' : '#e74c3c';

         if (!ok) {
           console.warn("[JiraNotes] helper not reachable");
           alert("Launch JiraNotes (menubar app) first, then try again.");
           return;
         }

         await loadNote();
       } catch (err) {
         console.error("[JiraNotes] click handler error:", err);
         alert("JiraNotes error: " + err);
       }
     }, true); // <-- capture = true so Jira can't swallow it
   panel.querySelector('#jira-notes-choose').addEventListener('click', async () => {
     try { await api('/choose', { method: 'POST' }); alert('Pick a folder via the JiraNotes menu bar app.'); } catch {}
   });
   panel.querySelector('#jira-notes-export').addEventListener('click', async () => {
     const tid = getTicketId(); if (!tid) return;
     const blob = new Blob([JSON.stringify({ ticketId: tid, text: textarea.value, updatedAt: new Date().toISOString() }, null, 2)], { type: "application/json" });
     const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = `${tid}.json`; a.click(); URL.revokeObjectURL(a.href);
   });
     
     
     
     // Add "Insert Date" button
     panel.querySelector('#jira-notes-actions').insertAdjacentHTML('beforeend', `
       <button id="jira-notes-insert-date" title="Insert current date">Date</button>
     `);

     // Save button
     panel.querySelector('#jira-notes-actions').insertAdjacentHTML('beforeend', `
       <button id="jira-notes-save" title="Save now">Save</button>
     `);
     panel.querySelector('#jira-notes-save').addEventListener('click', async () => {
       const tid = getTicketId(); if (!tid) return;
       const payload = { ticketId: tid, text: textarea.value, updatedAt: new Date().toISOString() };
       try {
         const res = await api(`/save?ticketId=${encodeURIComponent(tid)}`, { method: "POST", body: payload });
         console.log("[JiraNotes] saved", res);
         alert("Saved.");
       } catch (e) {
         console.error("[JiraNotes] save error", e);
         alert("Save failed: " + e);
       }
     });
     
     
     // Helper to insert text at cursor/selection and fire input
     function insertIntoTextarea(el, text) {
       const start = el.selectionStart ?? el.value.length;
       const end   = el.selectionEnd ?? el.value.length;

       const before = el.value.slice(0, start);
       const after  = el.value.slice(end);

       el.value = before + text + after;

       // move cursor to just after inserted text
       const pos = start + text.length;
       el.selectionStart = el.selectionEnd = pos;
       el.focus();

       // trigger autosave logic that listens to 'input'
       el.dispatchEvent(new Event('input', { bubbles: true }));
     }

     // Optional: tweak the format here
     function formatToday({ withTime = false } = {}) {
       const d = new Date();
       const yyyy = d.getFullYear();
       const mm = String(d.getMonth() + 1).padStart(2, '0');
       const dd = String(d.getDate()).padStart(2, '0');

       if (!withTime) return `${yyyy}-${mm}-${dd}`;

       const hh = String(d.getHours()).padStart(2, '0');
       const mi = String(d.getMinutes()).padStart(2, '0');
       return `${yyyy}-${mm}-${dd} ${hh}:${mi}`;
     }

     panel.querySelector('#jira-notes-insert-date').addEventListener('click', () => {
       // change to { withTime: true } if you want date+time
       insertIntoTextarea(textarea, `\n# ${formatToday({ withTime: true })}\n`);
     });

   // Resize
   const h = panel.querySelector('#jira-notes-resize');
   let resizing=false,sx=0,sy=0,sw=0,sh=0;
   h.addEventListener('mousedown', e => { resizing=true; sx=e.clientX; sy=e.clientY; sw=panel.offsetWidth; sh=panel.offsetHeight; e.preventDefault(); });
   document.addEventListener('mousemove', e => { if(!resizing) return; const dx=sx-e.clientX, dy=sy-e.clientY; panel.style.width=Math.max(260, sw+dx)+'px'; panel.style.height=Math.max(180, sh+dy)+'px'; });
   document.addEventListener('mouseup', ()=>{resizing=false;});

   // Auto-save
   let t=null; textarea.addEventListener('input', () => { clearTimeout(t); t=setTimeout(saveNote, 500); });

   // React to Jira’s SPA route changes
   let last=location.href; setInterval(()=>{ if(location.href!==last){ last=location.href; loadNote(); } },1000);
   loadNote();
 })();


