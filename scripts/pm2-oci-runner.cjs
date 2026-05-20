const { spawn } = require("node:child_process");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
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

process.on("SIGINT", () => forwardSignal("SIGINT"));
process.on("SIGTERM", () => forwardSignal("SIGTERM"));

child.on("exit", (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
    return;
  }

  process.exit(code ?? 1);
});

child.on("error", (error) => {
  console.error(error);
  process.exit(1);
});
