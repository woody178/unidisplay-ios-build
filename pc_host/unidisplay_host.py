#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
UniDisplay PC 發送端主機程式 (Windows / macOS / Linux 通用)
支援：
1. 🍎 iPad / iPhone Type-C 有線直連（內建原生 Apple usbmuxd 協定，直連 127.0.0.1:27015 轉發至 iPad 埠 23456）
2. 🤖 Android Type-C 有線直連（自動呼叫 adb forward tcp:23456 tcp:23456）
3. 🌐 USB 網路共享 (USB Tethering / NCM / RNDIS) 或區域網路 IP 直連
4. 🖥️ 單頁式圖形控制介面 (Tkinter GUI) + 自動讀取行動裝置點對點解析度 + ACK 智慧防延遲流控
"""

import io
import json
import os
import plistlib
import socket
import struct
import subprocess
import sys
import threading
import time

try:
    import tkinter as tk
    from tkinter import ttk, messagebox
    HAS_TK = True
except ImportError:
    tk = None
    ttk = None
    messagebox = None
    HAS_TK = False

# 嘗試載入高速截圖與影像壓縮套件
try:
    import mss
except ImportError:
    mss = None

try:
    from PIL import Image
except ImportError:
    Image = None


VIEWER_PORT = 23456
USBMUXD_ADDR = ("127.0.0.1", 27015)


# ==============================================================================
# 1. 原生 Apple usbmuxd Type-C 通訊實作（免安裝第三方 iOS 套件，直通 iPad/iPhone）
# ==============================================================================
class UsbmuxdClient:
    """透過 Windows (Apple Mobile Device Service) 或 macOS/Linux usbmuxd 走 Type-C 線直連 iPad/iPhone"""

    @staticmethod
    def _connect_daemon():
        if sys.platform in ("win32", "cygwin"):
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(2.5)
            sock.connect(USBMUXD_ADDR)
            return sock
        else:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(2.5)
            sock.connect("/var/run/usbmuxd")
            return sock

    @staticmethod
    def _send_plist(sock, payload_dict, tag=1):
        body = plistlib.dumps(payload_dict)
        length = 16 + len(body)
        # header: length(4B LE), version=1(4B LE), type=8 plist(4B LE), tag(4B LE)
        header = struct.pack("<IIII", length, 1, 8, tag)
        sock.sendall(header + body)

    @staticmethod
    def _recv_plist(sock):
        header = b""
        while len(header) < 16:
            chunk = sock.recv(16 - len(header))
            if not chunk:
                raise ConnectionError("usbmuxd 中斷連線")
            header += chunk
        length, version, msg_type, tag = struct.unpack("<IIII", header)
        body_len = length - 16
        body = b""
        while len(body) < body_len:
            chunk = sock.recv(body_len - len(body))
            if not chunk:
                raise ConnectionError("usbmuxd 讀取不完整")
            body += chunk
        return plistlib.loads(body)

    @classmethod
    def list_ios_devices(cls):
        """列出所有透過 Type-C / Lightning 插在電腦上的 iPad / iPhone"""
        try:
            sock = cls._connect_daemon()
            cls._send_plist(
                sock,
                {
                    "MessageType": "ListDevices",
                    "ClientVersionString": "UniDisplay-1.0",
                    "ProgName": "UniDisplayHost",
                },
                tag=1,
            )
            resp = cls._recv_plist(sock)
            sock.close()
            devices = []
            for item in resp.get("DeviceList", []):
                props = item.get("Properties", {})
                if props.get("ConnectionType") == "USB":
                    devices.append(
                        {
                            "device_id": item.get("DeviceID"),
                            "serial": props.get("SerialNumber", "Unknown"),
                            "product_id": props.get("ProductID", 0),
                        }
                    )
            return devices
        except Exception:
            return []

    @classmethod
    def connect_usb_port(cls, device_id: int, port: int = VIEWER_PORT) -> socket.socket:
        """將此 Socket 直接橋接進 iPad/iPhone 上的 TCP 埠號 (走 Type-C USB 高速通道)"""
        sock = cls._connect_daemon()
        # usbmuxd Connect 要求 PortNumber 為 network byte order (big-endian uint16)
        be_port = socket.htons(port)
        cls._send_plist(
            sock,
            {
                "MessageType": "Connect",
                "ClientVersionString": "UniDisplay-1.0",
                "ProgName": "UniDisplayHost",
                "DeviceID": int(device_id),
                "PortNumber": int(be_port),
            },
            tag=2,
        )
        resp = cls._recv_plist(sock)
        result_code = resp.get("Number", -1)
        if result_code != 0:
            sock.close()
            raise RuntimeError(
                f"無法連線至 iPad/iPhone 埠號 {port} (錯誤碼 {result_code})，請確認 iPad 已打開「UniDisplay 第二螢幕」App！"
            )
        sock.settimeout(None)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        return sock


# ==============================================================================
# 2. Android ADB Type-C 通訊輔助
# ==============================================================================
class AdbHelper:
    @staticmethod
    def list_android_devices():
        try:
            out = subprocess.check_output(
                ["adb", "devices", "-l"], stderr=subprocess.STDOUT, timeout=2.5
            ).decode("utf-8", errors="ignore")
            devs = []
            for line in out.splitlines()[1:]:
                line = line.strip()
                if not line or "offline" in line:
                    continue
                parts = line.split()
                if len(parts) >= 2 and parts[1] == "device":
                    serial = parts[0]
                    model = "Android"
                    for p in parts[2:]:
                        if p.startswith("model:"):
                            model = p.split(":", 1)[1]
                    devs.append({"serial": serial, "model": model})
            return devs
        except Exception:
            return []

    @staticmethod
    def connect_adb_usb(serial: str, port: int = VIEWER_PORT) -> socket.socket:
        subprocess.check_call(
            ["adb", "-s", serial, "forward", f"tcp:{port}", f"tcp:{port}"],
            timeout=3.0,
        )
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(3.0)
        sock.connect(("127.0.0.1", port))
        sock.settimeout(None)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        return sock


# ==============================================================================
# 3. 單頁式 PC 主機控制台 (GUI) 與高速串流核心
# ==============================================================================
class UniDisplayHostGUI:
    def __init__(self, root):
        self.root = root
        self.root.title("UniDisplay 跨平台第二螢幕 — PC 發送端 (iOS / Android Type-C 一線通)")
        self.root.geometry("680x580")
        self.root.configure(bg="#0F172A")

        self.streaming = False
        self.stream_thread = None
        self.active_sock = None
        self.client_info_str = "尚未收到行動裝置回報解析度"
        self.in_flight_frames = 0
        self.last_ack_time = 0.0

        self.monitors = []
        self.targets = []

        self._build_ui()
        self._refresh_monitors()
        self._refresh_targets()

    def _build_ui(self):
        style = ttk.Style()
        style.theme_use("clam")

        main = tk.Frame(self.root, bg="#0F172A", padx=20, pady=16)
        main.pack(fill=tk.BOTH, expand=True)

        # 標題
        tk.Label(
            main,
            text="🖥️ UniDisplay 跨平台第二螢幕 (PC 發送端)",
            font=("Microsoft JhengHei UI", 16, "bold"),
            fg="#38BDF8",
            bg="#0F172A",
        ).pack(anchor="w")
        tk.Label(
            main,
            text="一條 Type-C 線直連 iPad / iPhone (LiveContainer) 與 Android 手機作為延伸第二螢幕",
            font=("Microsoft JhengHei UI", 10),
            fg="#94A3B8",
            bg="#0F172A",
        ).pack(anchor="w", pady=(2, 14))

        # 區塊 1：選擇要傳送的 PC 螢幕
        f1 = tk.LabelFrame(
            main,
            text=" ① 選擇要投射出去的 PC 螢幕（建議選擇延伸的第 2 螢幕） ",
            font=("Microsoft JhengHei UI", 10, "bold"),
            fg="#E2E8F0",
            bg="#1E293B",
            padx=12,
            pady=10,
        )
        f1.pack(fill=tk.X, pady=6)

        row1 = tk.Frame(f1, bg="#1E293B")
        row1.pack(fill=tk.X)
        self.mon_var = tk.StringVar()
        self.mon_combo = ttk.Combobox(
            row1, textvariable=self.mon_var, state="readonly", width=52
        )
        self.mon_combo.pack(side=tk.LEFT, padx=(0, 8))
        tk.Button(
            row1,
            text="🔄 重新偵測螢幕",
            command=self._refresh_monitors,
            bg="#334155",
            fg="white",
            relief=tk.FLAT,
            padx=10,
        ).pack(side=tk.LEFT)

        # 區塊 2：選擇 Type-C 連接裝置或 IP
        f2 = tk.LabelFrame(
            main,
            text=" ② 選擇接收端裝置（Type-C USB 自動偵測 ／ 或輸入 IP） ",
            font=("Microsoft JhengHei UI", 10, "bold"),
            fg="#E2E8F0",
            bg="#1E293B",
            padx=12,
            pady=10,
        )
        f2.pack(fill=tk.X, pady=6)

        row2 = tk.Frame(f2, bg="#1E293B")
        row2.pack(fill=tk.X)
        self.target_var = tk.StringVar()
        self.target_combo = ttk.Combobox(
            row2, textvariable=self.target_var, state="readonly", width=52
        )
        self.target_combo.pack(side=tk.LEFT, padx=(0, 8))
        tk.Button(
            row2,
            text="🔍 掃描 Type-C 裝置",
            command=self._refresh_targets,
            bg="#0284C7",
            fg="white",
            relief=tk.FLAT,
            padx=10,
        ).pack(side=tk.LEFT)

        row2_ip = tk.Frame(f2, bg="#1E293B")
        row2_ip.pack(fill=tk.X, pady=(8, 0))
        tk.Label(
            row2_ip,
            text="或指定裝置 IP（USB網路共享/Wi-Fi）：",
            fg="#CBD5E1",
            bg="#1E293B",
            font=("Microsoft JhengHei UI", 9),
        ).pack(side=tk.LEFT)
        self.custom_ip_var = tk.StringVar(value="")
        tk.Entry(
            row2_ip,
            textvariable=self.custom_ip_var,
            width=24,
            bg="#0F172A",
            fg="#38BDF8",
            insertbackground="white",
        ).pack(side=tk.LEFT, padx=6)
        tk.Label(
            row2_ip,
            text="（留空則優先走上方選中的 Type-C USB 通道）",
            fg="#64748B",
            bg="#1E293B",
            font=("Microsoft JhengHei UI", 9),
        ).pack(side=tk.LEFT)

        # 區塊 3：畫質、更新率與縮放（單頁即時連動）
        f3 = tk.LabelFrame(
            main,
            text=" ③ 傳輸畫質、幀率與解析度縮放（串流中可即時調整） ",
            font=("Microsoft JhengHei UI", 10, "bold"),
            fg="#E2E8F0",
            bg="#1E293B",
            padx=12,
            pady=10,
        )
        f3.pack(fill=tk.X, pady=6)

        row3 = tk.Frame(f3, bg="#1E293B")
        row3.pack(fill=tk.X)

        tk.Label(row3, text="目標 FPS：", fg="#CBD5E1", bg="#1E293B").pack(side=tk.LEFT)
        self.fps_var = tk.IntVar(value=60)
        ttk.Combobox(
            row3, textvariable=self.fps_var, values=[30, 45, 60], width=6, state="readonly"
        ).pack(side=tk.LEFT, padx=(4, 16))

        tk.Label(row3, text="影像品質：", fg="#CBD5E1", bg="#1E293B").pack(side=tk.LEFT)
        self.qual_var = tk.IntVar(value=82)
        ttk.Combobox(
            row3,
            textvariable=self.qual_var,
            values=[65, 75, 82, 90, 95],
            width=6,
            state="readonly",
        ).pack(side=tk.LEFT, padx=(4, 16))

        tk.Label(row3, text="解析度縮放：", fg="#CBD5E1", bg="#1E293B").pack(side=tk.LEFT)
        self.scale_var = tk.StringVar(value="100%")
        ttk.Combobox(
            row3,
            textvariable=self.scale_var,
            values=["100%", "85%", "75%", "60%"],
            width=8,
            state="readonly",
        ).pack(side=tk.LEFT, padx=4)

        # 區塊 4：啟動 / 停止按鈕與即時狀態
        btn_frame = tk.Frame(main, bg="#0F172A", pady=12)
        btn_frame.pack(fill=tk.X)

        self.start_btn = tk.Button(
            btn_frame,
            text="🚀 開始投射第二螢幕",
            command=self._toggle_stream,
            font=("Microsoft JhengHei UI", 12, "bold"),
            bg="#10B981",
            fg="white",
            activebackground="#059669",
            relief=tk.FLAT,
            pady=10,
        )
        self.start_btn.pack(fill=tk.X)

        self.status_lbl = tk.Label(
            main,
            text="狀態：待命中。請先將 iPad 或 Android 手機插上 Type-C 線並打開「UniDisplay 第二螢幕」App。",
            font=("Microsoft JhengHei UI", 10),
            fg="#67E8F9",
            bg="#0F172A",
            wraplength=630,
            justify="left",
        )
        self.status_lbl.pack(anchor="w", pady=4)

        self.client_lbl = tk.Label(
            main,
            text="行動端資訊：尚未連線",
            font=("Microsoft JhengHei UI", 9),
            fg="#94A3B8",
            bg="#0F172A",
        )
        self.client_lbl.pack(anchor="w")

    def _refresh_monitors(self):
        with mss.mss() as sct:
            self.monitors = sct.monitors
        items = []
        for idx, m in enumerate(self.monitors):
            if idx == 0:
                items.append(
                    f"[0] 全部螢幕合併 ({m['width']}x{m['height']})"
                )
            else:
                tag = "主螢幕" if idx == 1 else f"延伸第 {idx} 螢幕 ★推薦"
                items.append(
                    f"[{idx}] 螢幕 {idx} - {tag} ({m['width']}x{m['height']} @ {m['left']},{m['top']})"
                )
        self.mon_combo["values"] = items
        # 若有多顆螢幕，預設自動選第 2 顆（延伸螢幕）
        if len(items) > 2:
            self.mon_combo.current(2)
        elif len(items) > 1:
            self.mon_combo.current(1)

    def _refresh_targets(self):
        self.targets = []
        labels = []

        # 1. 掃描 Apple usbmuxd 上的 iPad / iPhone
        ios_devs = UsbmuxdClient.list_ios_devices()
        for d in ios_devs:
            self.targets.append({"type": "ios_usb", "data": d})
            labels.append(
                f"🍎 [Type-C 直連] iPad / iPhone (DeviceID={d['device_id']}, SN={d['serial'][:10]}...)"
            )

        # 2. 掃描 Android ADB 上的手機
        and_devs = AdbHelper.list_android_devices()
        for d in and_devs:
            self.targets.append({"type": "android_usb", "data": d})
            labels.append(
                f"🤖 [Type-C 直連] Android {d['model']} ({d['serial']})"
            )

        if not labels:
            self.targets.append({"type": "none", "data": None})
            labels.append("⚠️ 未偵測到 USB 裝置（請確認已插線，或在下方輸入裝置 IP）")

        self.target_combo["values"] = labels
        self.target_combo.current(0)

    def _toggle_stream(self):
        if self.streaming:
            self.streaming = False
            try:
                if self.active_sock:
                    self.active_sock.close()
            except Exception:
                pass
            self.start_btn.configure(text="🚀 開始投射第二螢幕", bg="#10B981")
            self.status_lbl.configure(text="狀態：已停止投射。")
        else:
            self.streaming = True
            self.start_btn.configure(text="⏹️ 停止投射", bg="#EF4444")
            self.stream_thread = threading.Thread(
                target=self._stream_worker, daemon=True
            )
            self.stream_thread.start()

    def _connect_target_socket(self) -> socket.socket:
        custom_ip = self.custom_ip_var.get().strip()
        if custom_ip:
            host = custom_ip
            port = VIEWER_PORT
            if ":" in custom_ip:
                h, p = custom_ip.split(":", 1)
                host, port = h.strip(), int(p.strip())
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(3.5)
            sock.connect((host, port))
            sock.settimeout(None)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            return sock

        idx = self.target_combo.current()
        if idx < 0 or idx >= len(self.targets):
            raise RuntimeError("請先選擇接收裝置或輸入 IP")
        t = self.targets[idx]
        if t["type"] == "ios_usb":
            return UsbmuxdClient.connect_usb_port(
                t["data"]["device_id"], VIEWER_PORT
            )
        elif t["type"] == "android_usb":
            return AdbHelper.connect_adb_usb(
                t["data"]["serial"], VIEWER_PORT
            )
        else:
            raise RuntimeError(
                "未偵測到 Type-C 裝置！\n"
                "• 若接 iPad/iPhone：請確認電腦有裝 Apple 驅動 (iTunes / Apple Devices) 且平板已信任此電腦。\n"
                "• 若接 Android：請開啟 USB 偵錯，或在下方直接輸入手機畫面上的 IP。"
            )

    def _recv_reader_loop(self, sock: socket.socket):
        """背景讀取行動端傳回的 Hello 解析度握手與 ACK 流控訊號"""
        buf = b""
        try:
            while self.streaming and sock == self.active_sock:
                chunk = sock.recv(1024)
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    text = line.decode("utf-8", errors="ignore").strip()
                    if text == "ACK":
                        if self.in_flight_frames > 0:
                            self.in_flight_frames -= 1
                        self.last_ack_time = time.time()
                    elif text.startswith("{"):
                        try:
                            info = json.loads(text)
                            if info.get("type") == "hello":
                                pw = info.get("physicalWidth")
                                ph = info.get("physicalHeight")
                                plat = info.get("platform", "").upper()
                                self.root.after(
                                    0,
                                    lambda: self.client_lbl.configure(
                                        text=f"📱 行動端已握手：{plat} 裝置 ｜ 點對點真實解析度：{pw} × {ph} px"
                                    ),
                                )
                        except Exception:
                            pass
        except Exception:
            pass

    def _stream_worker(self):
        try:
            self._set_status("正在透過 Type-C / 網路建立連線...")
            sock = self._connect_target_socket()
            self.active_sock = sock
            self.in_flight_frames = 0
            self.last_ack_time = time.time()

            threading.Thread(
                target=self._recv_reader_loop, args=(sock,), daemon=True
            ).start()

            mon_idx = self.mon_combo.current()
            if mon_idx < 0:
                mon_idx = 1

            seq = 0
            fps_count = 0
            byte_count = 0
            stat_t0 = time.time()

            with mss.mss() as sct:
                while self.streaming:
                    t_frame_start = time.time()
                    target_fps = max(10, int(self.fps_var.get()))
                    frame_interval = 1.0 / target_fps

                    # 智慧防積壓流控：若超過 2 幀尚未收到行動端解碼 ACK（且未逾時 0.3s），稍作等待保證零延遲
                    if (
                        self.in_flight_frames > 2
                        and (time.time() - self.last_ack_time) < 0.3
                    ):
                        time.sleep(0.002)
                        continue

                    monitors = sct.monitors
                    mon = (
                        monitors[mon_idx]
                        if mon_idx < len(monitors)
                        else monitors[1]
                    )
                    raw = sct.grab(mon)
                    img = Image.frombytes("RGB", raw.size, raw.bgra, "raw", "BGRX")

                    scale_str = self.scale_var.get().replace("%", "")
                    scale = int(scale_str) / 100.0 if scale_str.isdigit() else 1.0
                    w, h = img.size
                    if scale < 0.99:
                        w = max(320, int(w * scale))
                        h = max(240, int(h * scale))
                        img = img.resize((w, h), Image.Resampling.BILINEAR)

                    qual = int(self.qual_var.get())
                    bio = io.BytesIO()
                    img.save(bio, format="JPEG", quality=qual, subsampling=0)
                    payload = bio.getvalue()

                    seq = (seq + 1) & 0xFFFFFFFF
                    # 16-byte Header: 'UDSP'(4B) + len(4B BE) + width(2B BE) + height(2B BE) + seq(4B BE)
                    header = struct.pack(
                        ">4sIHHI", b"UDSP", len(payload), w, h, seq
                    )
                    sock.sendall(header + payload)
                    self.in_flight_frames += 1

                    fps_count += 1
                    byte_count += len(payload) + 16
                    now = time.time()
                    if now - stat_t0 >= 1.0:
                        mbps = (byte_count * 8) / (1024 * 1024) / (now - stat_t0)
                        real_fps = fps_count / (now - stat_t0)
                        self._set_status(
                            f"🟢 正在高速投射中 ｜ 實測：{real_fps:.0f} FPS ｜ 流量：{mbps:.1f} Mbps ｜ 輸出解析度：{w}×{h}"
                        )
                        fps_count = 0
                        byte_count = 0
                        stat_t0 = now

                    elapsed = time.time() - t_frame_start
                    if elapsed < frame_interval:
                        time.sleep(frame_interval - elapsed)

        except Exception as e:
            self._set_status(f"❌ 連線或投射中斷：{e}")
        finally:
            self.streaming = False
            self.root.after(
                0,
                lambda: self.start_btn.configure(
                    text="🚀 開始投射第二螢幕", bg="#10B981"
                ),
            )

    def _set_status(self, msg: str):
        self.root.after(0, lambda: self.status_lbl.configure(text=msg))


if __name__ == "__main__":
    if mss is None or Image is None:
        print("正在自動安裝必要的高速畫面擷取套件 (mss, pillow)...")
        subprocess.check_call([sys.executable, "-m", "pip", "install", "mss", "pillow"])
        import mss
        from PIL import Image
    if HAS_TK:
        root = tk.Tk()
        app = UniDisplayHostGUI(root)
        root.mainloop()
    else:
        print("此環境未安裝 tkinter，已載入核心通訊模組 (UsbmuxdClient / AdbHelper)。")
