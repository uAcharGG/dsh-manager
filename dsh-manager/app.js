// dsh 管理面板前端逻辑
'use strict';

const state = {
  currentTab: 'launch',
  status: null,
  logCursor: { launch: 0, plugin: 0 },
  pendingStart: false,   // 本次会话内是否点击过「启动服务」
  startedAt: null,       // 启动动作发生时间（用于 60s 超时检测）
  busy: false,           // 插件操作进行中
  failCount: 0,          // 后端连续连接失败次数
  failWarned: false,     // 是否已给出"无法连接"提示
};

// ── 工具 ───────────────────────────────────────────────────────────────────

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// 带超时的 API 请求：轮询类 3s 快速失败；操作类（启动/停止/重启/安装/卸载）传较长时间
async function api(path, opts, timeoutMs) {
  const ms = timeoutMs || 3000;
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), ms);
  try {
    const res = await fetch(path, Object.assign({}, opts, { signal: ctrl.signal }));
    if (!res.ok) {
      const t = await res.text().catch(() => '');
      throw new Error(path + ' -> ' + res.status + ' ' + t);
    }
    return res.json();
  } finally {
    clearTimeout(timer);
  }
}

function appendLogLine(el, line) {
  const div = document.createElement('div');
  div.innerHTML = colorizeLine(line);
  el.appendChild(div);
  el.scrollTop = el.scrollHeight;
}

// 彩色分级：时间戳 / info|ok|warn|error / [dsh] 前缀
function colorizeLine(line) {
  const m = String(line).match(/^(\[\d{2}:\d{2}:\d{2}\])\s*(info|ok|warn|error|debug)?\s*(.*)$/);
  if (!m) return escapeHtml(line);
  let out = '<span class="log-time">' + escapeHtml(m[1]) + '</span> ';
  let rest = m[3] || '';
  if (m[2]) {
    const cls = m[2] === 'ok' ? 'log-success'
             : m[2] === 'warn' ? 'log-warn'
             : m[2] === 'error' ? 'log-error'
             : m[2] === 'debug' ? 'log-time'
             : 'log-info';
    out += '<span class="' + cls + '">' + m[2].padEnd(7) + '</span> ' + escapeHtml(rest);
    return out;
  }
  const dm = rest.match(/^(\[dsh\])(.*)$/);
  if (dm) {
    out += '<span class="log-time">' + escapeHtml(dm[1]) + '</span>' + escapeHtml(dm[2]);
  } else {
    out += escapeHtml(rest);
  }
  return out;
}

// ── 标签切换 ───────────────────────────────────────────────────────────────

function switchTab(tab) {
  state.currentTab = tab;
  document.querySelectorAll('.ds-nav-item').forEach(el => el.classList.remove('active'));
  document.querySelector('.ds-nav-item[data-tab="' + tab + '"]').classList.add('active');
  document.getElementById('tab-launch').classList.toggle('ds-hidden', tab !== 'launch');
  document.getElementById('tab-plugins').classList.toggle('ds-hidden', tab !== 'plugins');
  document.getElementById('page-title').textContent = tab === 'launch' ? '一键启动' : '插件管理';
  if (tab === 'plugins') {
    refreshPlugins();
  }
}

// ── 状态轮询 ───────────────────────────────────────────────────────────────

async function refreshStatus() {
  try {
    const st = await api('/api/status');
    state.status = st;
    state.failCount = 0;
    state.failWarned = false;
    const dot = document.getElementById('status-dot');
    const text = document.getElementById('status-text');
    const addr = document.getElementById('service-addr');
    const btnStart = document.getElementById('btn-start');
    const btnStop = document.getElementById('btn-stop');
    const btnRestart = document.getElementById('btn-restart');

    if (st.running) {
      dot.classList.remove('offline');
      text.textContent = '服务运行中';
      addr.textContent = st.url;
      addr.classList.remove('offline');
      addr.title = '点击打开 ' + st.url;
      btnStart.disabled = true;
      btnStop.disabled = false;
      btnRestart.disabled = false;
      if (state.pendingStart) {
        state.pendingStart = false;
        appendLogLine(document.getElementById('launch-log'),
          '[' + now() + '] ok      服务已就绪：' + st.url);
        try { window.open(st.url, '_blank'); } catch (e) { /* 弹窗被拦截时点击地址即可 */ }
      }
    } else {
      dot.classList.add('offline');
      text.textContent = '服务已停止';
      addr.textContent = '—';
      addr.classList.add('offline');
      addr.title = '';
      btnStart.disabled = false;
      btnStop.disabled = true;
      btnRestart.disabled = false;
      // 启动超时检测：60 秒未就绪 -> 明确提示并引导查看运行日志（错误原因在其中）
      if (state.pendingStart && state.startedAt) {
        if (Date.now() - state.startedAt > 60000) {
          state.pendingStart = false;
          state.startedAt = null;
          appendLogLine(document.getElementById('launch-log'),
            '[' + now() + '] error   启动超时：端口 ' + st.port + ' 60 秒内未就绪。请查看上方运行日志中的错误信息（如端口被占用等），然后重试。');
        }
      }
    }

    // 插件操作 busy 状态
    const wasBusy = state.busy;
    state.busy = !!st.pluginBusy;
    const btnInstall = document.getElementById('btn-install');
    const busyHint = document.getElementById('install-busy');
    if (state.busy) {
      btnInstall.disabled = true;
      btnInstall.textContent = '安装中...';
      busyHint.classList.remove('ds-hidden');
    } else {
      btnInstall.disabled = false;
      btnInstall.innerHTML = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg> 安装';
      busyHint.classList.add('ds-hidden');
      if (wasBusy) {
        refreshPlugins();
      }
    }
  } catch (e) {
    // 后端不可达：明确提示而不是永远"检测中"
    state.failCount++;
    const dot = document.getElementById('status-dot');
    const text = document.getElementById('status-text');
    dot.classList.add('offline');
    if (state.failCount >= 3) {
      text.textContent = '管理服务无响应（' + state.failCount + ' 次）';
      if (!state.failWarned) {
        state.failWarned = true;
        appendLogLine(document.getElementById('launch-log'),
          '[' + now() + '] error   无法连接管理服务。请关闭本页，重新双击 dsh-manager.cmd 启动面板。');
      }
    } else {
      text.textContent = '正在连接管理服务...';
    }
  }
}

function now() {
  return new Date().toTimeString().slice(0, 8);
}

// ── 日志轮询 ───────────────────────────────────────────────────────────────

async function pollLogs() {
  try {
    for (const key of ['launch', 'plugin']) {
      const r = await api('/api/logs?log=' + key + '&cursor=' + state.logCursor[key]);
      const lines = r.lines || [];
      if (lines.length) {
        const el = document.getElementById(key === 'launch' ? 'launch-log' : 'plugin-log');
        for (const line of lines) appendLogLine(el, line);
      }
      state.logCursor[key] = r.cursor;
    }
  } catch (e) { /* 下次轮询重试 */ }
}

// ── 服务控制 ───────────────────────────────────────────────────────────────
// 操作类请求用 30s 超时：启动/停止/重启在服务端可能耗时数秒（重启=停止+等待+启动）

async function startService() {
  try {
    state.pendingStart = true;
    state.startedAt = Date.now();
    const r = await api('/api/start', { method: 'POST' }, 30000);
    appendLogLine(document.getElementById('launch-log'),
      '[' + now() + '] info    ' + (r.message || (r.already ? '服务已在运行' : '已发起启动，等待端口就绪...')));
    await refreshStatus();
  } catch (e) {
    state.pendingStart = false;
    appendLogLine(document.getElementById('launch-log'),
      '[' + now() + '] error   启动请求失败：' + e.message);
    alert('启动失败：' + e.message);
  }
}

async function stopService() {
  if (!confirm('确定停止 dsh Web 服务吗？\n\n将结束 dsh 服务及其全部相关进程（包括运行 dsh web 的命令行进程）。')) return;
  try {
    const r = await api('/api/stop', { method: 'POST' }, 30000);
    appendLogLine(document.getElementById('launch-log'),
      '[' + now() + '] info    ' + (r.message || '已发送停止请求'));
    await refreshStatus();
  } catch (e) {
    appendLogLine(document.getElementById('launch-log'),
      '[' + now() + '] error   停止请求失败：' + e.message);
    alert('停止失败：' + e.message);
  }
}

async function restartService() {
  if (!confirm('确定重启 dsh Web 服务吗？\n\n将先停止服务及全部相关进程，再重新启动。')) return;
  try {
    const r = await api('/api/restart', { method: 'POST' }, 30000);
    appendLogLine(document.getElementById('launch-log'),
      '[' + now() + '] info    ' + (r.message || '重启指令已发送'));
    state.pendingStart = true;
    state.startedAt = Date.now();
    await refreshStatus();
  } catch (e) {
    appendLogLine(document.getElementById('launch-log'),
      '[' + now() + '] error   重启请求失败：' + e.message);
    alert('重启失败：' + e.message);
  }
}

async function copyAddr() {
  const addrEl = document.getElementById('service-addr');
  const addr = addrEl.textContent;
  if (!addr || addr === '—') return;
  try {
    await navigator.clipboard.writeText(addr);
    appendLogLine(document.getElementById('launch-log'), '[' + now() + '] ok      地址已复制：' + addr);
  } catch (e) {
    appendLogLine(document.getElementById('launch-log'), '[' + now() + '] error   复制失败');
  }
}

// 点击服务地址打开
document.addEventListener('DOMContentLoaded', () => {
  const addr = document.getElementById('service-addr');
  addr.addEventListener('click', () => {
    if (state.status && state.status.running) window.open(state.status.url, '_blank');
  });
});

// ── 插件管理 ───────────────────────────────────────────────────────────────

async function loadProfiles() {
  try {
    const profiles = await api('/api/profiles');
    const sel = document.getElementById('profile-select');
    sel.innerHTML = '';
    profiles.forEach(p => {
      const opt = document.createElement('option');
      opt.value = p;
      opt.textContent = p;
      sel.appendChild(opt);
    });
    sel.value = 'web';
  } catch (e) { /* 忽略 */ }
}

async function refreshPlugins() {
  const profile = document.getElementById('profile-select').value || 'web';
  const list = document.getElementById('plugin-list');
  list.innerHTML = '<div class="ds-plugin-empty">加载中...</div>';
  try {
    const r = await api('/api/plugins?profile=' + encodeURIComponent(profile));
    list.innerHTML = '';
    if (!r.plugins || !r.plugins.length) {
      const empty = document.createElement('div');
      empty.className = 'ds-plugin-empty';
      empty.textContent = '该 profile 暂无插件';
      list.appendChild(empty);
      return;
    }
    r.plugins.forEach(p => {
      list.appendChild(buildPluginRow(p, profile));
    });
  } catch (e) {
    list.innerHTML = '<div class="ds-plugin-empty">加载失败：' + escapeHtml(e.message) + '</div>';
  }
}

function buildPluginRow(p, profile) {
  const row = document.createElement('div');
  row.className = 'ds-plugin-row';

  const info = document.createElement('div');
  info.className = 'ds-plugin-info';
  const name = document.createElement('span');
  name.className = 'ds-plugin-name';
  name.textContent = p.name;
  // 第二行：功能描述（从插件包 README 提取；没有则显示 "-"）
  const desc = document.createElement('span');
  desc.className = 'ds-plugin-desc';
  desc.textContent = p.readme || '-';
  info.appendChild(name);
  info.appendChild(desc);
  // 第三行：文件来源路径（无前缀）；内置组合包显示"内置模板组合包"
  const src = document.createElement('span');
  src.className = 'ds-plugin-source';
  if (p.kind === 'template') {
    src.textContent = '内置模板组合包';
  } else {
    src.textContent = (p.source || '-') + (p.version ? ' · v' + p.version : '');
  }
  info.appendChild(src);
  row.appendChild(info);

  const actions = document.createElement('div');
  actions.className = 'ds-plugin-actions';

  if (p.locked) {
    const lock = document.createElement('span');
    lock.className = 'ds-plugin-locked';
    lock.textContent = '内置';
    actions.appendChild(lock);
  } else {
    const toggle = document.createElement('div');
    toggle.className = 'ds-toggle' + (p.enabled ? ' on' : '');
    toggle.title = p.enabled ? '点击停用' : '点击启用';
    toggle.addEventListener('click', async () => {
      if (state.busy) return;
      toggle.classList.toggle('on');
      try {
        const r = await api('/api/plugins/toggle', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ profile: profile, name: p.name, enable: !p.enabled }),
        }, 15000);
        appendLogLine(document.getElementById('plugin-log'),
          '[' + now() + '] info    ' + (r.message || '已切换'));
      } catch (e) {
        toggle.classList.toggle('on');
        alert('切换失败：' + e.message);
      }
      await refreshPlugins();
    });
    actions.appendChild(toggle);
  }

  const un = document.createElement('button');
  un.className = 'ds-btn ghost small';
  un.textContent = '卸载';
  un.addEventListener('click', () => uninstallPlugin(p, profile));
  actions.appendChild(un);

  row.appendChild(actions);
  return row;
}

async function uninstallPlugin(p, profile) {
  if (state.busy) return;
  if (!confirm('卸载插件 ' + p.name + ' ？（同时移除依赖和组合层）')) return;
  // dsh 运行中禁止卸载：组合层变更需重启 dsh 才生效
  if (state.status && state.status.running) {
    alert('dsh 服务正在运行，不能卸载插件。\n\n请先点击「停止服务」关闭 dsh，再卸载插件；卸载完成后点击「启动服务」重启 dsh。');
    return;
  }
  try {
    const r = await api('/api/plugins/uninstall', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ profile: profile, name: p.name }),
    }, 15000);
    appendLogLine(document.getElementById('plugin-log'),
      '[' + now() + '] info    ' + (r.message || '已开始卸载'));
    await refreshStatus();
  } catch (e) {
    alert('卸载失败：' + e.message);
  }
}

async function installPlugin() {
  if (state.busy) return;
  const source = document.getElementById('install-source').value;
  const input = document.getElementById('install-input').value.trim();
  if (!input) {
    appendLogLine(document.getElementById('plugin-log'),
      '[' + now() + '] warn    请输入插件名称或路径');
    return;
  }
  // dsh 运行中禁止安装：组合层变更需重启 dsh 才生效
  if (state.status && state.status.running) {
    alert('dsh 服务正在运行，不能安装插件。\n\n请先点击「停止服务」关闭 dsh，再安装插件；安装完成后点击「启动服务」重启 dsh。');
    return;
  }
  const profile = document.getElementById('profile-select').value || 'web';
  try {
    const r = await api('/api/plugins/install', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ profile: profile, source: source, spec: input }),
    }, 15000);
    appendLogLine(document.getElementById('plugin-log'),
      '[' + now() + '] info    ' + (r.message || '已开始安装'));
    if (r.ok) document.getElementById('install-input').value = '';
    await refreshStatus();
  } catch (e) {
    alert('安装失败：' + e.message);
  }
}

// 通用目录选择：后端弹原生文件夹对话框（独立进程），轮询取回所选路径
async function pickDirectory(desc, onPicked) {
  // 打开对话框（失败自动重试一次，规避偶发的连接超时）
  let opened = false;
  let r = null;
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      r = await api('/api/pick-directory', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ desc: desc }),
      }, 10000);
      break;
    } catch (e) {
      if (attempt === 0) {
        await new Promise(res => setTimeout(res, 700));
        continue;
      }
      alert('无法打开文件夹选择器：' + e.message);
      return;
    }
  }
  if (!r || !r.ok) {
    alert('无法打开文件夹选择器：' + (r && r.message || '未知错误'));
    return;
  }
  opened = true;
  // 轮询选择结果（最长 120 秒；对话框关闭后由后端写入结果文件）
  const deadline = Date.now() + 120000;
  while (Date.now() < deadline) {
    await new Promise(resolve => setTimeout(resolve, 600));
    const res = await api('/api/pick-directory-result', {}, 5000).catch(() => null);
    if (res && res.done) {
      if (res.path) onPicked(res.path);
      return; // 取消也到此结束
    }
  }
  alert('选择文件夹超时，请重试');
}

// 插件安装：点击文件夹图标选择本地插件文件夹
async function pickLocalFolder() {
  await pickDirectory('选择插件文件夹', (p) => {
    const src = document.getElementById('install-source');
    src.value = 'local';
    src.dispatchEvent(new Event('change'));
    document.getElementById('install-input').value = p;
    appendLogLine(document.getElementById('plugin-log'),
      '[' + now() + '] info    已选择本地插件文件夹：' + p + '（将按 link: 形式安装）');
  });
}

// ── dsh 启动路径 ───────────────────────────────────────────────────────────

// 读取后端当前生效的 dsh 启动路径
async function loadDshConfig() {
  try {
    const cfg = await api('/api/config');
    document.getElementById('dsh-checkout').value = cfg.checkout || '';
  } catch (e) { /* 后端未就绪时输入框保持为空 */ }
}

// 服务控制区：点击文件夹图标选择 dsh 源码目录，选择后立即保存
async function pickDshDir() {
  await pickDirectory('选择 dsh 启动目录（deepseek-harness 源码目录）', (p) => {
    document.getElementById('dsh-checkout').value = p;
    saveDshConfig();
  });
}

// 保存 dsh 启动路径
async function saveDshConfig() {
  const val = document.getElementById('dsh-checkout').value.trim();
  if (!val) {
    alert('请输入 dsh 启动路径');
    return;
  }
  const btn = document.getElementById('btn-save-dsh');
  btn.disabled = true;
  try {
    const r = await api('/api/config', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ checkout: val }),
    }, 15000);
    appendLogLine(document.getElementById('launch-log'),
      '[' + now() + '] ' + (r.ok ? 'ok      启动路径已保存：' : 'warn    保存失败：') + (r.checkout || r.message || ''));
    if (!r.ok) alert('保存失败：' + (r.message || '未知错误'));
  } catch (e) {
    alert('保存失败：' + e.message);
  } finally {
    btn.disabled = false;
  }
}

// 来源切换时更新输入框占位提示
document.addEventListener('DOMContentLoaded', () => {
  const src = document.getElementById('install-source');
  const input = document.getElementById('install-input');
  src.addEventListener('change', () => {
    const hints = {
      npm: '输入 npm 包名，如：deepseek-r1-connector',
      local: '输入本地绝对路径，如：D:\\plugins\\my-plugin',
      git: '输入 git 仓库地址，如：git+https://github.com/user/repo.git',
      tarball: '输入 .tgz 压缩包路径',
    };
    input.placeholder = hints[src.value] || '输入插件名称或路径';
  });
});

// ── 启动 ───────────────────────────────────────────────────────────────────

async function init() {
  await loadProfiles();
  await loadDshConfig();
  await refreshStatus();
  await pollLogs();
  await refreshPlugins();
  setInterval(refreshStatus, 1500);
  setInterval(pollLogs, 1500);
}

document.addEventListener('DOMContentLoaded', init);
