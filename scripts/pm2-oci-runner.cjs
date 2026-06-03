const { spawn } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const appName = process.env.PM2_APP_NAME || process.env.name || "oci-instance-creator";
const cleanupPm2DumpOnSuccess =
  !/^(0|false|no)$/i.test(process.env.CLEANUP_PM2_DUMP_ON_SUCCESS || "true");
const isWindows = process.platform === "win32";
const script = path.join(
  root,
  "scripts",
  isWindows ? "oci-create-loop.ps1" : "oci-create-loop.sh",
);
const command = isWindows ? "powershell.exe" : "bash";
const args = isWindows
  ? ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script]
  : [script];

const child = spawn(
  command,
  args,
  {
    cwd: root,
    env: {
      ...process.env,
      OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING: "True",
    },
    stdio: "inherit",
    windowsHide: true,
  },
);

const forwardSignal = (signal) => {
  if (!child.killed) {
    child.kill(signal);
  }
};

const getPm2Home = () => process.env.PM2_HOME || path.join(os.homedir(), ".pm2");

const removeAppFromPm2Dump = () => {
  if (!cleanupPm2DumpOnSuccess) {
    return;
  }

  const pm2Home = getPm2Home();
  const dumpFile = path.join(pm2Home, "dump.pm2");
  if (!fs.existsSync(dumpFile)) {
    return;
  }

  let apps;
  try {
    apps = JSON.parse(fs.readFileSync(dumpFile, "utf8"));
  } catch (error) {
    console.error(`Failed to read PM2 dump for cleanup: ${error.message}`);
    return;
  }

  if (!Array.isArray(apps)) {
    return;
  }

  const filtered = apps.filter((app) => app?.name !== appName);
  if (filtered.length === apps.length) {
    return;
  }

  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const backupFile = path.join(pm2Home, `dump.pm2.backup-${timestamp}`);
  try {
    fs.copyFileSync(dumpFile, backupFile);
    fs.writeFileSync(dumpFile, `${JSON.stringify(filtered, null, 2)}\n`, "utf8");
    console.log(`Removed ${appName} from PM2 dump after success.`);
  } catch (error) {
    console.error(`Failed to update PM2 dump after success: ${error.message}`);
  }
};

const removeStalePidFiles = () => {
  if (!cleanupPm2DumpOnSuccess) {
    return;
  }

  const pidDir = path.join(getPm2Home(), "pids");
  if (!fs.existsSync(pidDir)) {
    return;
  }

  for (const fileName of fs.readdirSync(pidDir)) {
    if (!fileName.startsWith(`${appName}-`) || !fileName.endsWith(".pid")) {
      continue;
    }

    try {
      fs.rmSync(path.join(pidDir, fileName), { force: true });
    } catch (error) {
      console.error(`Failed to remove stale PM2 pid file ${fileName}: ${error.message}`);
    }
  }
};

process.on("SIGINT", () => forwardSignal("SIGINT"));
process.on("SIGTERM", () => forwardSignal("SIGTERM"));

child.on("exit", (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
    return;
  }

  if (code === 0) {
    removeAppFromPm2Dump();
    removeStalePidFiles();
  }

  process.exit(code ?? 1);
});

child.on("error", (error) => {
  console.error(error);
  process.exit(1);
});
