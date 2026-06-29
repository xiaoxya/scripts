const express = require('express');
const cron = require('node-cron');
const { exec } = require('child_process');
const fs = require('fs');
const path = require('path');
const util = require('util');
const execAsync = util.promisify(exec);

const app = express();
const PORT = process.env.PORT || 3000;
const HOST = process.env.HOST || '0.0.0.0'; // 0.0.0.0 = 允许局域网访问
const DATA_FILE = path.join(__dirname, 'data', 'tasks.json');

// Middleware
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// Data helpers
function readTasks() {
  if (!fs.existsSync(DATA_FILE)) return [];
  try {
    return JSON.parse(fs.readFileSync(DATA_FILE, 'utf-8'));
  } catch {
    return [];
  }
}

function writeTasks(tasks) {
  fs.writeFileSync(DATA_FILE, JSON.stringify(tasks, null, 2), 'utf-8');
}

// Run a cron job and manage it
const activeJobs = new Map();

function runCronTask(taskId) {
  // Read the latest task from disk (avoid stale closure)
  const tasks = readTasks();
  const task = tasks.find(t => t.id === taskId);
  if (!task || !task.enabled) return;

  // Remove existing job if any
  if (activeJobs.has(taskId)) {
    activeJobs.get(taskId).stop();
  }

  const job = cron.schedule(task.schedule, async () => {
    const startTime = new Date();
    let output = '';
    let error = '';
    let exitCode = 0;

    try {
      const { stdout, stderr } = await execAsync(task.command, {
        timeout: 3600000, // 1 hour timeout
        maxBuffer: 1024 * 1024 * 10 // 10MB buffer
      });
      output = stdout;
      error = stderr;
      exitCode = 0;
    } catch (e) {
      output = e.stdout || '';
      error = e.stderr || e.message || 'Unknown error';
      exitCode = e.exitCode || 1;
    }

    const combinedOutput = (output + '\n' + error).trim().slice(0, 2000);
    const lastRun = startTime.toISOString();

    // Update task state
    const allTasks = readTasks();
    const idx = allTasks.findIndex(t => t.id === taskId);
    if (idx !== -1) {
      allTasks[idx].lastRun = lastRun;
      allTasks[idx].lastOutput = exitCode === 0 ? combinedOutput : `[exit ${exitCode}] ${combinedOutput}`;
      allTasks[idx].runCount = (allTasks[idx].runCount || 0) + 1;
      allTasks[idx].lastExitCode = exitCode;
      writeTasks(allTasks);
    }

    const duration = `${((new Date() - startTime) / 1000).toFixed(1)}s`;
    const status = exitCode === 0 ? '✅' : '❌';
    console.log(`[cron] ${status} Task "${task.name}" - ${duration} ${exitCode === 0 ? 'OK' : 'FAILED'}`);
  }, { scheduled: true, timezone: 'Asia/Shanghai' });

  activeJobs.set(taskId, job);
}

// Execute a task manually
async function executeTask(taskId) {
  const tasks = readTasks();
  const task = tasks.find(t => t.id === taskId);
  if (!task) return { success: false, error: 'Task not found' };

  const startTime = new Date();
  let output = '';
  let error = '';
  let exitCode = 0;

  try {
    const { stdout, stderr } = await execAsync(task.command, {
      timeout: 3600000,
      maxBuffer: 1024 * 1024 * 10
    });
    output = stdout;
    error = stderr;
    exitCode = 0;
  } catch (e) {
    output = e.stdout || '';
    error = e.stderr || e.message || 'Unknown error';
    exitCode = e.exitCode || 1;
  }

  const combinedOutput = (output + '\n' + error).trim().slice(0, 2000);
  const allTasks = readTasks();
  const idx = allTasks.findIndex(t => t.id === taskId);
  if (idx !== -1) {
    allTasks[idx].lastRun = startTime.toISOString();
    allTasks[idx].lastOutput = exitCode === 0 ? combinedOutput : `[exit ${exitCode}] ${combinedOutput}`;
    allTasks[idx].runCount = (allTasks[idx].runCount || 0) + 1;
    allTasks[idx].lastExitCode = exitCode;
    writeTasks(allTasks);
  }

  const duration = `${((new Date() - startTime) / 1000).toFixed(1)}s`;
  return { success: true, exitCode, output: combinedOutput, duration };
}

// Routes
app.get('/api/tasks', (req, res) => {
  const tasks = readTasks();
  res.json(tasks);
});

app.post('/api/tasks', (req, res) => {
  const { name, schedule, command, enabled = true } = req.body;
  if (!name || !schedule || !command) {
    return res.status(400).json({ error: 'name, schedule, and command are required' });
  }

  const task = {
    id: Date.now().toString(),
    name,
    schedule,
    command,
    enabled,
    createdAt: new Date().toISOString(),
    lastRun: null,
    lastOutput: '',
    runCount: 0
  };

  const tasks = readTasks();
  tasks.push(task);
  writeTasks(tasks);

  if (enabled) {
    runCronTask(task.id);
  }

  res.json(task);
});

app.put('/api/tasks/:id', (req, res) => {
  const tasks = readTasks();
  const idx = tasks.findIndex(t => t.id === req.params.id);
  if (idx === -1) return res.status(404).json({ error: 'Task not found' });

  const update = req.body;
  Object.assign(tasks[idx], update);

  // If schedule/command changed, restart the job
  if (update.schedule || update.command) {
    if (update.enabled !== false) {
      runCronTask(tasks[idx].id);
    } else {
      if (activeJobs.has(tasks[idx].id)) {
        activeJobs.get(tasks[idx].id).stop();
        activeJobs.delete(tasks[idx].id);
      }
    }
  }

  writeTasks(tasks);
  res.json(tasks[idx]);
});

app.post('/api/tasks/:id/run', async (req, res) => {
  const result = await executeTask(req.params.id);
  if (!result.success) return res.status(404).json({ error: result.error });
  res.json(result);
});

app.delete('/api/tasks/:id', (req, res) => {
  let tasks = readTasks();
  const task = tasks.find(t => t.id === req.params.id);
  tasks = tasks.filter(t => t.id !== req.params.id);
  writeTasks(tasks);

  if (task && activeJobs.has(task.id)) {
    activeJobs.get(task.id).stop();
    activeJobs.delete(task.id);
  }

  res.json({ success: true });
});

// Serve the web UI
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// Start server
app.listen(PORT, HOST, () => {
  console.log(`Cron Manager running at http://${HOST}:${PORT}`);
  console.log(`  Local:  http://localhost:${PORT}`);
  console.log(`  Network: http://<your-ip>:${PORT}`);

  // Restore existing tasks
  const tasks = readTasks();
  tasks.forEach(task => {
    if (task.enabled) {
      runCronTask(task);
    }
  });
});
