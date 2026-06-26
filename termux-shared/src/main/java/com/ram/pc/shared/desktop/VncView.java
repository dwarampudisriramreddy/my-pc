package com.ram.pc.shared.desktop;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Rect;
import android.util.AttributeSet;
import android.view.MotionEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;

import androidx.annotation.NonNull;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.net.Socket;

public class VncView extends SurfaceView implements SurfaceHolder.Callback, Runnable {
    private static final int PROTO_TIMEOUT = 5000;

    private Thread vncThread;
    private volatile boolean running;
    private volatile boolean connected;
    private String host;
    private int port;
    private int fbWidth = 1280;
    private int fbHeight = 720;
    private Bitmap framebuffer;
    private final Paint statusPaint = new Paint();
    private final Rect dstRect = new Rect();
    private Socket socket;
    private DataInputStream in;
    private DataOutputStream out;

    public VncView(Context context) { super(context); init(); }
    public VncView(Context context, AttributeSet attrs) { super(context, attrs); init(); }
    public VncView(Context context, AttributeSet attrs, int defStyle) { super(context, attrs, defStyle); init(); }

    private void init() {
        getHolder().addCallback(this);
        statusPaint.setColor(Color.LTGRAY);
        statusPaint.setTextSize(28);
        statusPaint.setAntiAlias(true);
        statusPaint.setTextAlign(Paint.Align.CENTER);
    }

    @Override public void surfaceCreated(@NonNull SurfaceHolder holder) { drawStatus("Initializing..."); }
    @Override public void surfaceChanged(@NonNull SurfaceHolder holder, int f, int w, int h) {}
    @Override public void surfaceDestroyed(@NonNull SurfaceHolder holder) { disconnect(); }

    public void connect(String host, int port) {
        this.host = host;
        this.port = port;
        disconnect();
        running = true;
        vncThread = new Thread(this, "VNC-Viewer");
        vncThread.start();
    }

    public void disconnect() {
        running = false;
        connected = false;
        try { if (socket != null) socket.close(); } catch (IOException ignored) {}
        socket = null;
        if (vncThread != null && vncThread.isAlive()) {
            try { vncThread.join(1500); } catch (InterruptedException ignored) {}
        }
        vncThread = null;
    }

    public boolean isConnected() { return connected; }

    @Override
    public void run() {
        try {
            socket = new Socket(host, port);
            socket.setSoTimeout(PROTO_TIMEOUT);
            in = new DataInputStream(socket.getInputStream());
            out = new DataOutputStream(socket.getOutputStream());
            rfbHandshake();
            connected = true;
            drawStatus("Connected");
            while (running && connected) {
                if (!readFramebufferUpdate()) break;
            }
        } catch (Exception e) {
            if (running) drawStatus("VNC: " + e.getMessage());
        } finally {
            connected = false;
            try { if (socket != null) socket.close(); } catch (IOException ignored) {}
        }
    }

    private void rfbHandshake() throws IOException {
        byte[] verBytes = new byte[12];
        in.readFully(verBytes);
        out.write("RFB 003.003\n".getBytes());
        out.flush();
        int authCount = in.readInt();
        if (authCount == 0) {
            int secResult = in.readInt();
            if (secResult != 0) throw new IOException("VNC auth failed: " + secResult);
        } else {
            in.skipBytes(authCount * 4);
            out.write(1); out.flush();
        }
        out.write(1); out.flush();
        fbWidth = in.readUnsignedShort();
        fbHeight = in.readUnsignedShort();
        framebuffer = Bitmap.createBitmap(fbWidth, fbHeight, Bitmap.Config.ARGB_8888);
        in.skipBytes(18);
        setPixelFormat();
        requestFbUpdate();
    }

    private void setPixelFormat() throws IOException {
        out.write(0);
        out.write(0);
        out.write(1);
        out.write(0);
        out.write(new byte[4]);
        out.writeShort(32);
        out.writeByte(24);
        out.writeByte(0);
        out.writeByte(1);
        out.writeShort(255);
        out.writeShort(255);
        out.writeShort(255);
        out.writeByte(16);
        out.writeByte(8);
        out.writeByte(0);
        out.write(new byte[3]);
        out.flush();
    }

    private void requestFbUpdate() throws IOException {
        out.write(3);
        out.write(0);
        out.writeShort(0);
        out.writeShort(0);
        out.writeShort(fbWidth);
        out.writeShort(fbHeight);
        out.flush();
    }

    private boolean readFramebufferUpdate() throws IOException {
        int msgType = in.readUnsignedByte();
        if (msgType != 0) { in.skipBytes(3); return true; }
        in.skipBytes(1);
        int numRects = in.readUnsignedShort();
        for (int i = 0; i < numRects; i++) {
            int x = in.readUnsignedShort();
            int y = in.readUnsignedShort();
            int w = in.readUnsignedShort();
            int h = in.readUnsignedShort();
            int enc = in.readInt();
            if (enc == 0) {
                byte[] pixels = new byte[w * h * 4];
                in.readFully(pixels);
                int[] intPixels = new int[w * h];
                for (int py = 0; py < h; py++) {
                    for (int px = 0; px < w; px++) {
                        int idx = (py * w + px) * 4;
                        intPixels[py * w + px] = ((pixels[idx + 3] & 0xFF) << 24) |
                            ((pixels[idx] & 0xFF) << 16) |
                            ((pixels[idx + 1] & 0xFF) << 8) |
                            (pixels[idx + 2] & 0xFF);
                    }
                }
                synchronized (this) {
                    if (framebuffer != null) framebuffer.setPixels(intPixels, 0, w, x, y, w, h);
                }
            } else {
                in.skipBytes(w * h * 4);
            }
        }
        renderFrame();
        requestFbUpdate();
        return true;
    }

    private void renderFrame() {
        SurfaceHolder holder = getHolder();
        if (holder == null) return;
        Canvas canvas = holder.lockCanvas();
        if (canvas == null) return;
        try {
            int vw = getWidth();
            int vh = getHeight();
            if (vw <= 0) { vw = canvas.getWidth(); vh = canvas.getHeight(); }
            canvas.drawColor(Color.BLACK);
            Bitmap fb;
            synchronized (this) { fb = framebuffer; }
            if (fb != null && vw > 0 && vh > 0) {
                float scale = Math.min((float) vw / fb.getWidth(), (float) vh / fb.getHeight());
                int dw = Math.max(1, (int) (fb.getWidth() * scale));
                int dh = Math.max(1, (int) (fb.getHeight() * scale));
                dstRect.set((vw - dw) / 2, (vh - dh) / 2, (vw + dw) / 2, (vh + dh) / 2);
                canvas.drawBitmap(fb, null, dstRect, null);
            }
        } finally {
            holder.unlockCanvasAndPost(canvas);
        }
    }

    private void drawStatus(String msg) {
        SurfaceHolder holder = getHolder();
        if (holder == null) return;
        Canvas canvas = holder.lockCanvas();
        if (canvas == null) return;
        try {
            canvas.drawColor(Color.BLACK);
            if (msg != null) canvas.drawText(msg, canvas.getWidth() / 2f, canvas.getHeight() / 2f, statusPaint);
        } finally {
            holder.unlockCanvasAndPost(canvas);
        }
    }

    public void sendPointerEvent(int x, int y, int buttonMask) {
        if (!connected || out == null) return;
        try {
            out.write(5);
            out.write(buttonMask);
            out.writeShort(Math.max(0, Math.min(fbWidth - 1, x)));
            out.writeShort(Math.max(0, Math.min(fbHeight - 1, y)));
            out.flush();
        } catch (IOException ignored) {}
    }

    public void sendKeyEvent(int keysym, boolean down) {
        if (!connected || out == null) return;
        try {
            out.write(4);
            out.write(down ? 1 : 0);
            out.write(0);
            out.writeShort(keysym);
            out.flush();
        } catch (IOException ignored) {}
    }

    @Override
    public boolean onTouchEvent(MotionEvent event) {
        int action = event.getActionMasked();
        float x = (event.getX() / Math.max(1, getWidth())) * fbWidth;
        float y = (event.getY() / Math.max(1, getHeight())) * fbHeight;
        int btn = 0;
        switch (action) {
            case MotionEvent.ACTION_DOWN: btn = 1; break;
            case MotionEvent.ACTION_POINTER_DOWN: btn = 4; break;
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_POINTER_UP:
                btn = 0; break;
        }
        sendPointerEvent((int) x, (int) y, btn);
        return true;
    }
}
