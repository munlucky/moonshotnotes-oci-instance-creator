const path = require("node:path");

const root = __dirname;

module.exports = {
  apps: [
    {
      name: "oci-instance-creator",
      cwd: root,
      script: path.join(root, "scripts", "pm2-oci-runner.cjs"),
      exec_mode: "fork",
      instances: 1,
      autorestart: true,
      stop_exit_codes: [0],
      restart_delay: 60000,
      max_restarts: 20,
      min_uptime: 30000,
      out_file: path.join(root, "logs", "pm2-out.log"),
      error_file: path.join(root, "logs", "pm2-error.log"),
      merge_logs: true,
      time: true,
      env: {
        OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING: "True",
      },
    },
  ],
};
