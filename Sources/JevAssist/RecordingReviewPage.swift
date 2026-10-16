import Foundation

enum RecordingReviewPage {
    /// Local file input avoids browser file:// fetch restrictions. Screenshot
    /// paths are restricted to this run's hash-named images; text is never HTML.
    static let html = #"""
    <!doctype html>
    <html lang="en">
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' file:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'none'">
    <title>Jev Assist · Local replay</title>
    <style>
    :root { color-scheme:light dark; font:15px -apple-system,BlinkMacSystemFont,sans-serif; }
    * { box-sizing:border-box } body { margin:0; background:#101719; color:#e8efed; }
    main { max-width:1440px; margin:auto; padding:28px; }
    h1 { font-size:26px; margin:0 0 8px; } p { color:#a9bab5; line-height:1.5; }
    button,input::file-selector-button { background:#23443e; color:#eff9f5; border:1px solid #4a7065; border-radius:8px; padding:9px 14px; cursor:pointer; }
    button:disabled { opacity:.4; cursor:default; } input[type=file] { max-width:100%; }
    .bar { display:flex; flex-wrap:wrap; align-items:center; gap:12px; padding:16px 0; }
    #scrub { flex:1; min-width:180px; accent-color:#52c9ac; } #position { font-variant-numeric:tabular-nums; min-width:120px; }
    .columns { display:grid; grid-template-columns:minmax(0,2fr) minmax(260px,1fr); gap:20px; align-items:start; }
    .card { padding:20px; border:1px solid #2b3937; background:#172220; border-radius:14px; }
    h2 { color:#a9bab5; font-size:12px; letter-spacing:.06em; text-transform:uppercase; margin:0 0 10px; }
    #stage { position:relative; line-height:0; min-height:100px; }
    #screen { width:100%; height:auto; display:block; border-radius:8px; }
    .box { position:absolute; pointer-events:none; border-radius:5px; }
    #held { border:3px solid #54e2bc; background:#54e2bc12; box-shadow:0 0 0 1px #0b1411; z-index:3; }
    #candidate { border:3px dashed #ffbd69; z-index:2; }
    .sample { border:1.5px solid; z-index:1; }
    .sample span { position:absolute; top:1px; left:2px; padding:3px; border-radius:3px; background:#101719e8; font-size:11px; line-height:1; }
    #sample0 { border-color:#8ba6c7; color:#8ba6c7; } #sample1 { border-color:#b19ac8; color:#b19ac8; } #sample2 { border-color:#c69caa; color:#c69caa; }
    #sample1 span { left:auto; right:2px; } #sample2 span { top:auto; bottom:2px; }
    .sample-row { margin:12px 0 0; padding-left:10px; border-left:3px solid; white-space:pre-wrap; font-size:13px; line-height:1.5; }
    #sampleRow0 { border-color:#8ba6c7; } #sampleRow1 { border-color:#b19ac8; } #sampleRow2 { border-color:#c69caa; }
    #ensembleSummary { white-space:pre-wrap; font-size:13px; line-height:1.5; }
    .legend { font-size:13px; margin:12px 0 0; }
    .legend span { display:inline-block; margin-right:18px; } .teal { color:#54e2bc; } .amber { color:#ffbd69; }
    #transcript { white-space:pre-wrap; max-height:390px; overflow:auto; line-height:1.5; }
    #goal,#reason { white-space:pre-wrap; line-height:1.5; }
    #stats,#detail,#empty { font-size:13px; color:#a9bab5; line-height:1.5; }
    #status { color:#ffcd91; } [hidden] { display:none!important; }
    @media(max-width:850px) { .columns { grid-template-columns:1fr; } main { padding:18px; } }
    </style>
    <main>
      <h1>Session replay</h1>
      <p>Everything stays on this Mac. Choose <strong>events.ndjson</strong> from the same folder as this page.</p>
      <input id="file" type="file" accept=".ndjson,.jsonl,.txt" aria-label="Open this session’s events.ndjson">
      <p id="status" role="status"></p>
      <div class="bar">
        <button id="previous" disabled aria-label="Previous event">←</button>
        <button id="play" disabled>Play</button>
        <button id="next" disabled aria-label="Next event">→</button>
        <input id="scrub" type="range" min="0" max="0" value="0" disabled aria-label="Replay timeline">
        <span id="position">No session loaded</span>
      </div>
      <p id="stats"></p>
      <div class="columns">
        <section class="card">
          <div id="stage"><img id="screen" alt="Recorded request screenshot" hidden><div id="held" class="box" hidden></div><div id="candidate" class="box" hidden></div><div id="sample0" class="box sample" hidden><span>1</span></div><div id="sample1" class="box sample" hidden><span>2</span></div><div id="sample2" class="box sample" hidden><span>3</span></div></div>
          <p id="empty">Screenshots appear here when you load the event log.</p>
          <p class="legend"><span class="teal">Green: held highlight</span><span class="amber">Amber: final Jev suggestion</span><span>Numbered: original samples; dotted samples excluded</span></p>
          <p id="detail"></p>
        </section>
        <aside>
          <section class="card"><h2>What happened</h2><div id="reason">—</div></section><br>
          <section class="card" id="ensembleCard" hidden><h2>Three-call consensus</h2><div id="ensembleSummary"></div><div id="sampleRow0" class="sample-row" hidden></div><div id="sampleRow1" class="sample-row" hidden></div><div id="sampleRow2" class="sample-row" hidden></div></section><br>
          <section class="card"><h2>Keeping in mind</h2><div id="goal">—</div></section><br>
          <section class="card"><h2>Hearing you at this frame</h2><div id="transcript">—</div></section>
        </aside>
      </div>
    </main>
    <script>
    'use strict';
    const $ = id => document.getElementById(id);
    let timeline = [], index = 0, timer = null;
    const finite = x => typeof x === 'number' && Number.isFinite(x);
    const words = x => typeof x === 'string' ? x.replaceAll('_',' ') : '';
    function stop() { clearTimeout(timer); timer = null; $('play').textContent = 'Play'; }
    function rectInImage(rect, frame) {
      const s = frame?.screenBounds, c = frame?.imageContentRect;
      if (!rect || !s || !c || ![rect.x,rect.y,rect.width,rect.height,s.x,s.y,s.width,s.height,c.x,c.y,c.width,c.height].every(finite) || s.width<=0 || s.height<=0) return null;
      return {left:c.x+(rect.x-s.x)/s.width*c.width,top:c.y+(rect.y-s.y)/s.height*c.height,
              right:c.x+(rect.x+rect.width-s.x)/s.width*c.width,bottom:c.y+(rect.y+rect.height-s.y)/s.height*c.height};
    }
    function validBox(box) {
      return box && [box.left,box.right,box.top,box.bottom].every(finite) && box.left>=0 && box.top>=0 && box.right<=1.00001 && box.bottom<=1.00001 && box.right>box.left && box.bottom>box.top;
    }
    function draw(id, box) {
      const el = $(id);
      if (!validBox(box)) { el.hidden=true; return; }
      el.style.left=(box.left*100)+'%'; el.style.top=(box.top*100)+'%';
      el.style.width=((box.right-box.left)*100)+'%'; el.style.height=((box.bottom-box.top)*100)+'%'; el.hidden=false;
    }
    function renderEnsemble(event, hasImage) {
      const ensemble=event.kind==='decision'?event.ensemble:null;
      const samples=Array.isArray(ensemble?.samples)?ensemble.samples:[];
      const selected=new Set((Array.isArray(ensemble?.selected_indices)?ensemble.selected_indices:[]).filter(i=>Number.isInteger(i)&&i>=0&&i<samples.length));
      $('ensembleCard').hidden=!samples.length;
      $('ensembleSummary').textContent=samples.length
        ? 'Method: '+(words(ensemble.method)||'not recorded')+'\nSelected: '+([...selected].map(i=>i+1).join(', ')||'none')+(finite(ensemble.iou_threshold)?' · IoU threshold '+ensemble.iou_threshold.toFixed(2):'')+(!hasImage?'\nRequest screenshot unavailable; sample outlines hidden.':'')
        : '';
      for(let i=0;i<3;i++) {
        const sample=samples[i], outline=$('sample'+i), row=$('sampleRow'+i);
        draw('sample'+i,hasImage?sample?.box:null);
        outline.style.borderStyle=selected.has(i)?'solid':'dotted'; outline.style.opacity=selected.has(i)?'0.9':'0.55';
        row.hidden=!sample;
        if(sample) {
          const probability=value=>finite(value)?(value*100).toFixed(1)+'%':'unavailable';
          const bounds=validBox(sample.box)?'L '+sample.box.left.toFixed(3)+' · T '+sample.box.top.toFixed(3)+' · R '+sample.box.right.toFixed(3)+' · B '+sample.box.bottom.toFixed(3):(sample.box?'Invalid box':'No box');
          row.textContent='Sample '+(i+1)+' · '+(selected.has(i)?'selected':'excluded')+'\nConfidence '+probability(sample.confidence)+' · presence '+probability(sample.presence)+'\n'+bounds;
        } else { row.textContent=''; }
      }
    }
    function render() {
      const step = timeline[index]; if (!step) return;
      const e=step.event, f=step.frame, path=f?.imagePath;
      const validPath=typeof path==='string' && /^frames\/[a-f0-9]{64}\.jpg$/.test(path);
      $('screen').hidden=!validPath; $('empty').hidden=validPath;
      $('empty').textContent='The request image was not recorded for this event.';
      if (validPath) $('screen').src=path;
      draw('held', validPath ? (step.held?.targetRect ? rectInImage(step.held.targetRect,f) : (step.held?.frameID===f?.frameID ? step.held?.box : null)) : null);
      draw('candidate', validPath && e.kind==='decision' ? e.box : null);
      renderEnsemble(e,validPath);
      $('position').textContent=(index+1)+' / '+timeline.length;
      $('scrub').value=index;
      const ms=finite(e.elapsedMS)?e.elapsedMS:0;
      $('reason').textContent=(ms/1000).toFixed(1)+'s · '+words(e.kind)+(e.disposition?' · '+words(e.disposition):'')+(e.reason?'\n'+words(e.reason):'');
      $('goal').textContent=step.context?.goal || 'No selected goal';
      $('transcript').textContent=step.context?.transcript || 'No speech recorded yet';
      const detail=[];
      if (f?.appName) detail.push(f.appName); if (f?.windowTitle) detail.push(f.windowTitle);
      if (finite(e.latencyMS)) detail.push(Math.round(e.latencyMS)+' ms');
      if (finite(e.confidence)) detail.push('Confidence '+(e.confidence*100).toFixed(0)+'%');
      if (finite(e.presence)) detail.push('Presence '+(e.presence*100).toFixed(0)+'%');
      $('detail').textContent=detail.join(' · ');
      $('previous').disabled=index===0; $('next').disabled=index>=timeline.length-1;
    }
    function advance() {
      if (index>=timeline.length-1) { stop(); return; }
      const before=timeline[index].event.elapsedMS;
      index++; render();
      const after=timeline[index].event.elapsedMS;
      timer=setTimeout(advance,Math.max(60,Math.min(1500,finite(after-before)?after-before:200)));
    }
    $('file').addEventListener('change',async event=>{
      stop(); timeline=[]; index=0; $('status').textContent='';
      const file=event.target.files?.[0]; if (!file) return;
      if (file.size>128*1024*1024) { $('status').textContent='This event log is too large for the browser viewer. The NDJSON remains available for analysis.'; return; }
      const frames=new Map(); let context={transcript:'',goal:null},held=null,lastFrame=null,bad=0,decisions=0,displayed=0,latency=0,timed=0;
      for (const line of (await file.text()).split(/\r?\n/)) {
        if (!line.trim()) continue;
        let e; try { e=JSON.parse(line); } catch { bad++; continue; }
        if (!e || e.schemaVersion!==1 || typeof e.kind!=='string') { bad++; continue; }
        if (e.kind==='context') { context={transcript:typeof e.transcript==='string'?e.transcript:'',goal:typeof e.goal==='string'?e.goal:null}; continue; }
        if (e.kind==='frame' && typeof e.frameID==='string') {
          lastFrame={event:e,context}; frames.set(e.frameID,lastFrame);
          timeline.push({event:e,frame:e,context,held});
        } else if (e.kind==='decision') {
          decisions++; if (e.disposition==='displayed') displayed++;
          if (finite(e.latencyMS)) { latency+=e.latencyMS; timed++; }
          const input=frames.get(e.frameID);
          timeline.push({event:e,frame:input?.event,context:input?.context || context,held});
        } else if (e.kind==='highlight') {
          held=e.box || e.targetRect ? {box:e.box,targetRect:e.targetRect,frameID:e.frameID} : null;
          const input=e.box || e.targetRect ? frames.get(e.frameID) : lastFrame;
          timeline.push({event:e,frame:input?.event,context:input?.context || context,held});
        }
      }
      $('stats').textContent=frames.size+' request frames · '+decisions+' decisions · '+displayed+' displayed'+(timed?' · '+Math.round(latency/timed)+' ms average response':'');
      $('status').textContent=bad?bad+' incomplete or unsupported events skipped.':'';
      if (!timeline.length) $('status').textContent='No screen or guidance events in this recording yet.';
      $('scrub').max=Math.max(0,timeline.length-1); $('scrub').disabled=!timeline.length; $('play').disabled=!timeline.length;
      render();
    });
    $('scrub').addEventListener('input',()=>{stop();index=Number($('scrub').value);render();});
    $('previous').addEventListener('click',()=>{stop();index=Math.max(0,index-1);render();});
    $('next').addEventListener('click',()=>{stop();index=Math.min(timeline.length-1,index+1);render();});
    $('play').addEventListener('click',()=>{if(timer){stop();return;} if(index>=timeline.length-1)index=0; $('play').textContent='Pause';advance();});
    $('screen').addEventListener('error',()=>{
      $('screen').hidden=true;
      for(const id of ['held','candidate','sample0','sample1','sample2']) $(id).hidden=true;
      $('empty').hidden=false;$('empty').textContent='The matching screenshot is missing. Keep this page, events.ndjson, and the frames folder together.';
    });
    </script>
    </html>
    """#
}
