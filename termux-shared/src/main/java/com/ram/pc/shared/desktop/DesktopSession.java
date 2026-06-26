package com.ram.pc.shared.desktop;

import android.content.Context;
import android.os.AsyncTask;
import android.os.Environment;

import com.ram.pc.shared.logger.Logger;
import com.ram.pc.shared.termux.TermuxConstants;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;

public class DesktopSession {
    private static final String LOG_TAG = "DesktopSession";
    private static final int VNC_PORT = 5901;
    private static final String VNC_DISPLAY = ":1";

    private Process prootProcess;
    private boolean running;
    private String vncPassword = "termux";
    private final Context context;

    public DesktopSession(Context context) {
        this.context = context.getApplicationContext();
    }

    public interface SessionCallback {
        void onSessionStart(int port);
        void onSessionError(String error);
        void onSessionStop();
    }

    public void start(SessionCallback callback) {
        if (running) {
            callback.onSessionStart(VNC_PORT);
            return;
        }
        new StartTask(callback).execute();
    }

    public void stop() {
        running = false;
        if (prootProcess != null) {
            prootProcess.destroy();
            prootProcess = null;
        }
    }

    public boolean isRunning() { return running; }
    public int getPort() { return VNC_PORT; }

    private class StartTask extends AsyncTask<Void, String, Boolean> {
        private final SessionCallback callback;
        private String errorMsg;

        StartTask(SessionCallback cb) { this.callback = cb; }

        @Override
        protected Boolean doInBackground(Void... voids) {
            try {
                String installDir;
                File extUbuntuDir = context.getExternalFilesDir("ubuntu");
                if (extUbuntuDir != null) {
                    installDir = extUbuntuDir.getAbsolutePath();
                } else {
                    installDir = Environment.getExternalStorageDirectory().getAbsolutePath()
                        + "/Android/data/" + context.getPackageName() + "/files/ubuntu";
                }
                if (!new File(installDir).mkdirs() && !new File(installDir).isDirectory()) {
                    throw new IOException("Failed to create install directory: " + installDir);
                }
                String user = "termux";

                File vncDir = new File(installDir + "/home/" + user + "/.vnc");
                if (!vncDir.mkdirs() && !vncDir.isDirectory()) {
                    throw new IOException("Failed to create VNC directory: " + vncDir);
                }

                File xstartup = new File(vncDir, "xstartup");
                if (!xstartup.exists()) {
                    writeFile(xstartup,
                        "#!/bin/bash\n",
                        "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n",
                        "export LANG=C.UTF-8\n",
                        "exec startxfce4\n");
                    xstartup.setExecutable(true);
                }

                File passwdFile = new File(vncDir, "passwd");
                if (!passwdFile.exists()) {
                    writeVncPassword(passwdFile);
                }

                String bindings = "";
                for (String d : new String[]{"/dev", "/proc", "/sys", "/tmp", "/run", "/etc/resolv.conf"}) {
                    if (new File(d).exists()) bindings += " -b " + d;
                }
                if (new File("/dev/dri").exists()) bindings += " -b /dev/dri";
                if (new File("/dev/shm").exists()) bindings += " -b /dev/shm";

                String prootBin = TermuxConstants.TERMUX_BIN_PREFIX_DIR_PATH + "/proot";
                String cmd = prootBin + " -0 -r " + installDir + bindings +
                    " -w /home/" + user +
                    " /usr/bin/env -i HOME=/home/" + user +
                    " USER=" + user +
                    " PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" +
                    " TERM=xterm-256color LANG=C.UTF-8 DISPLAY=" + VNC_DISPLAY +
                    " su - " + user + " -c 'vncserver " + VNC_DISPLAY +
                    " -geometry 1280x720 -depth 24 -localhost -fg 2>&1'";

                prootProcess = Runtime.getRuntime().exec(new String[]{"sh", "-c", cmd});
                running = true;
                Thread.sleep(3000);

                try (java.net.Socket test = new java.net.Socket("127.0.0.1", VNC_PORT)) {
                    return true;
                } catch (IOException e) {
                    errorMsg = "VNC server not ready on port " + VNC_PORT;
                    return false;
                }
            } catch (Exception e) {
                errorMsg = "Desktop start failed: " + e.getMessage();
                Logger.logError(LOG_TAG, errorMsg);
                return false;
            }
        }

        @Override
        protected void onPostExecute(Boolean success) {
            if (success) {
                if (callback != null) callback.onSessionStart(VNC_PORT);
            } else {
                stop();
                if (callback != null) callback.onSessionError(errorMsg != null ? errorMsg : "Unknown error");
            }
        }
    }

    private void writeFile(File file, String... lines) throws IOException {
        try (OutputStream os = new FileOutputStream(file)) {
            for (String line : lines) os.write(line.getBytes());
        }
    }

    private void writeVncPassword(File file) throws IOException {
        byte[] obfuscated = new byte[8];
        for (int i = 0; i < 8; i++) {
            char c = i < vncPassword.length() ? vncPassword.charAt(i) : 0;
            obfuscated[i] = (byte) (c ^ 0xFF);
        }
        try (FileOutputStream fos = new FileOutputStream(file)) {
            fos.write(obfuscated);
        }
    }
}
