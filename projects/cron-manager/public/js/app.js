let tasks = [];

async function loadTasks() {
  try {
    const res = await fetch('/api/tasks');
    tasks = await res.json();
    renderTasks();
    updateStats();
  } catch (e) {
    console.error('Failed to load tasks:', e);
    showToast('加载失败，请检查网络连接');
  }
}

function formatTime(iso) {
  if (!iso) return '从未执行';
  return new Date(iso).toLocaleString('zh-CN', {
    month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit'
  });
}

function updateStats() {
  const total = tasks.length;
  const active = tasks.filter(t => t.enabled).length;
  const paused = total - active;
  const totalRuns = tasks.reduce((sum, t) => sum + (t.runCount || 0), 0);

  document.getElementById('statTotal').textContent = total;
  document.getElementById('statActive').textContent = active;
  document.getElementById('statPaused').textContent = paused;
  document.getElementById('statCommands').textContent = totalRuns;
}

function renderTasks() {
  const container = document.getElementById('taskList');
  if (tasks.length === 0) {
    container.innerHTML = `
      <div class="empty-state">
        <div class="empty-icon">
          <svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>
        </div>
        <p class="empty-title">暂无定时任务</p>
        <p class="empty-desc">点击上方"新建任务"按钮，添加你的第一个定时任务</p>
      </div>`;
    return;
  }

  container.innerHTML = tasks.map(t => `
    <div class="task-card ${t.enabled ? '' : 'disabled'}" data-id="${t.id}">
      <div class="task-card-top">
        <span class="task-name">
          ${esc(t.name)}
          <span class="task-badge ${t.enabled ? 'badge-active' : 'badge-inactive'}">
            <span class="badge-dot"></span>
            ${t.enabled ? '运行中' : '已暂停'}
          </span>
        </span>
      </div>
      <div class="task-details">
        <div class="task-detail">
          <span class="task-detail-label">Cron</span>
          <span class="task-detail-value">${esc(t.schedule)}</span>
        </div>
        <div class="task-detail">
          <span class="task-detail-label">命令</span>
          <span class="task-detail-value" title="${esc(t.command)}">${esc(t.command)}</span>
        </div>
        <div class="task-detail">
          <span class="task-detail-label">上次运行</span>
          <span class="task-detail-value">${formatTime(t.lastRun)}</span>
        </div>
        <div class="task-detail">
          <span class="task-detail-label">运行次数</span>
          <span class="task-detail-value">${t.runCount || 0}</span>
        </div>
      </div>
      ${t.lastOutput ? `
      <div class="task-output" data-output="${t.id}">
        <div class="output-header" onclick="toggleOutput('${t.id}')">
          <span class="output-status ${t.lastExitCode === 0 ? 'success' : 'error'}">
            ${t.lastExitCode === 0 ? '✅' : '❌ [exit ' + t.lastExitCode + ']'}
          </span>
          <span class="output-toggle">展开</span>
        </div>
        <div class="output-body hidden" id="output-${t.id}">${esc(t.lastOutput)}</div>
      </div>` : ''}
      <div class="task-actions">
        <button class="btn btn-sm btn-run" onclick="runTask('${t.id}')" id="run-btn-${t.id}">
          <svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><polygon points="5 3 19 12 5 21 5 3"/></svg>
          立即执行
        </button>
        <button class="btn btn-sm btn-edit" onclick="editTask('${t.id}')">编辑</button>
        <button class="btn btn-sm ${t.enabled ? 'btn-toggle-active' : 'btn-toggle-inactive'}" onclick="toggleTask('${t.id}')">
          ${t.enabled ? '暂停' : '启用'}
        </button>
        <button class="btn btn-sm btn-delete" onclick="deleteTask('${t.id}')">删除</button>
      </div>
    </div>
  `).join('');
}

function esc(str) {
  const div = document.createElement('div');
  div.textContent = str;
  return div.innerHTML;
}

// Modal
function openModal() {
  document.getElementById('modal').classList.remove('hidden');
  document.getElementById('modalTitle').textContent = '新建任务';
  document.getElementById('submitBtn').textContent = '创建任务';
  document.getElementById('taskForm').reset();
  document.getElementById('taskId').value = '';
  document.getElementById('taskEnabled').checked = true;
}

function closeModal() {
  document.getElementById('modal').classList.add('hidden');
}

async function handleSubmit(e) {
  e.preventDefault();
  const id = document.getElementById('taskId').value;
  const data = {
    name: document.getElementById('taskName').value,
    schedule: document.getElementById('taskSchedule').value,
    command: document.getElementById('taskCommand').value,
    enabled: document.getElementById('taskEnabled').checked
  };

  try {
    if (id) {
      await fetch(`/api/tasks/${id}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data)
      });
      showToast('任务已更新');
    } else {
      await fetch('/api/tasks', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data)
      });
      showToast('任务已创建');
    }
    closeModal();
    loadTasks();
  } catch (err) {
    console.error('Failed to save task:', err);
    showToast('保存失败');
  }
}

function setCron(expr) {
  document.getElementById('taskSchedule').value = expr;
}

async function editTask(id) {
  const task = tasks.find(t => t.id === id);
  if (!task) return;

  document.getElementById('taskId').value = task.id;
  document.getElementById('taskName').value = task.name;
  document.getElementById('taskSchedule').value = task.schedule;
  document.getElementById('taskCommand').value = task.command;
  document.getElementById('taskEnabled').checked = task.enabled;
  document.getElementById('modalTitle').textContent = '编辑任务';
  document.getElementById('submitBtn').textContent = '保存修改';
  document.getElementById('modal').classList.remove('hidden');
}

async function toggleTask(id) {
  const task = tasks.find(t => t.id === id);
  if (!task) return;

  try {
    await fetch(`/api/tasks/${id}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ enabled: !task.enabled })
    });
    loadTasks();
    showToast(task.enabled ? '任务已暂停' : '任务已启用');
  } catch (err) {
    console.error('Failed to toggle:', err);
    showToast('操作失败');
  }
}

async function runTask(id) {
  const btn = document.getElementById('run-btn-' + id);
  if (!btn) return;

  btn.disabled = true;
  btn.innerHTML = '<span class="spinner"></span> 执行中...';

  try {
    const res = await fetch(`/api/tasks/${id}/run`, { method: 'POST' });
    const result = await res.json();

    if (result.success) {
      const status = result.exitCode === 0 ? '✅ 执行成功' : '❌ 执行失败';
      showToast(`${status} (${result.duration})`);
    } else {
      showToast(result.error || '执行失败');
    }
  } catch (err) {
    console.error('Failed to run task:', err);
    showToast('执行失败');
  }

  btn.disabled = false;
  btn.innerHTML = `
    <svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><polygon points="5 3 19 12 5 21 5 3"/></svg>
    立即执行
  `;
  loadTasks();
}

async function deleteTask(id) {
  if (!confirm('确定要删除这个任务吗？')) return;

  try {
    await fetch(`/api/tasks/${id}`, { method: 'DELETE' });
    showToast('任务已删除');
    loadTasks();
  } catch (err) {
    console.error('Failed to delete:', err);
    showToast('删除失败');
  }
}

// Toast
function showToast(msg) {
  const toast = document.getElementById('toast');
  toast.textContent = msg;
  toast.classList.add('show');
  setTimeout(() => toast.classList.remove('show'), 2500);
}

function toggleOutput(id) {
  const body = document.getElementById('output-' + id);
  if (!body) return;

  body.classList.toggle('hidden');
  const header = body.parentElement.querySelector('.output-header');
  const toggle = header?.querySelector('.output-toggle');
  if (toggle) {
    toggle.textContent = body.classList.contains('hidden') ? '展开' : '收起';
  }
}

// Close modal on backdrop click
document.getElementById('modal').addEventListener('click', (e) => {
  if (e.target === document.getElementById('modal') || e.target.classList.contains('modal-backdrop')) closeModal();
});

// Keyboard shortcut: Escape to close
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') closeModal();
});

// Init
loadTasks();
