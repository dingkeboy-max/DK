using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Management;
using System.Net.Sockets;
using System.Windows.Forms;

namespace NetToggle
{
    public class AdapterInfo
    {
        public string Name { get; set; }
        public bool NetEnabled { get; set; }
        public string Status { get; set; }
        public string DisplayName => $"{Name}   [{Status}]";
    }

    public class MainForm : Form
    {
        private ListBox adaptersListBox;
        private Label statusLabel;
        private PictureBox dot;
        private Button btnRefresh, btnDisable, btnEnable;
        private CheckBox chkWatch;
        private NumericUpDown numInterval;
        private TextBox logBox;
        private NotifyIcon notifyIcon;
        private ContextMenuStrip trayMenu;
        private System.Threading.Timer bgTimer;
        private int tickCount = 0;

        public MainForm()
        {
            InitializeComponent();
            RefreshAdapters();
            Log("NetToggle 已启动（管理员模式）");
        }

        private void InitializeComponent()
        {
            Text = "NetToggle - 一键断网 / 联网";
            Size = new Size(560, 440);
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(480, 380);
            BackColor = Color.FromArgb(245, 247, 250);

            // 状态
            statusLabel = new Label
            {
                Location = new Point(16, 14),
                Size = new Size(360, 22),
                Font = new Font("Microsoft YaHei", 11, FontStyle.Bold),
                Text = "当前网络：检测中…"
            };
            Controls.Add(statusLabel);

            dot = new PictureBox
            {
                Location = new Point(390, 16),
                Size = new Size(16, 16),
                BackColor = Color.Gray
            };
            Controls.Add(dot);

            // 适配器列表
            var lbLabel = new Label
            {
                Location = new Point(16, 48),
                Size = new Size(220, 18),
                Text = "网络适配器（点选要操作的）"
            };
            Controls.Add(lbLabel);

            adaptersListBox = new ListBox
            {
                Location = new Point(16, 70),
                Size = new Size(300, 180),
                DisplayMember = "DisplayName",
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Bottom
            };
            Controls.Add(adaptersListBox);

            // 按钮
            btnRefresh = new Button
            {
                Location = new Point(330, 70),
                Size = new Size(190, 34),
                Text = "刷新列表"
            };
            btnRefresh.Click += (s, e) => RefreshAdapters();
            Controls.Add(btnRefresh);

            btnDisable = new Button
            {
                Location = new Point(330, 112),
                Size = new Size(190, 38),
                Text = "⛔ 一键断网",
                BackColor = Color.FromArgb(255, 235, 235)
            };
            btnDisable.Click += (s, e) =>
            {
                var a = SelectedAdapter(); if (a == null) return;
                SetAdapterState(a.Name, false);
                System.Threading.Thread.Sleep(600);
                RefreshAdapters();
            };
            Controls.Add(btnDisable);

            btnEnable = new Button
            {
                Location = new Point(330, 158),
                Size = new Size(190, 38),
                Text = "✅ 一键联网",
                BackColor = Color.FromArgb(225, 245, 230)
            };
            btnEnable.Click += (s, e) =>
            {
                var a = SelectedAdapter(); if (a == null) return;
                SetAdapterState(a.Name, true);
                System.Threading.Thread.Sleep(600);
                RefreshAdapters();
            };
            Controls.Add(btnEnable);

            // 自动守护
            chkWatch = new CheckBox
            {
                Location = new Point(330, 206),
                Size = new Size(200, 22),
                Text = "自动守护（掉线自动重连）"
            };
            chkWatch.CheckedChanged += (s, e) =>
                Log(chkWatch.Checked ? $"自动守护已开启（每 {numInterval.Value} 秒检测）" : "自动守护已关闭");
            Controls.Add(chkWatch);

            var lblInterval = new Label
            {
                Location = new Point(330, 234),
                Size = new Size(120, 18),
                Text = "检测间隔(秒)："
            };
            Controls.Add(lblInterval);

            numInterval = new NumericUpDown
            {
                Location = new Point(456, 232),
                Size = new Size(64, 22),
                Minimum = 2,
                Maximum = 60,
                Value = 5
            };
            Controls.Add(numInterval);

            // 日志
            var logLabel = new Label
            {
                Location = new Point(16, 258),
                Size = new Size(120, 18),
                Text = "操作日志"
            };
            Controls.Add(logLabel);

            logBox = new TextBox
            {
                Location = new Point(16, 280),
                Size = new Size(508, 100),
                Multiline = true,
                ScrollBars = ScrollBars.Vertical,
                ReadOnly = true,
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Bottom
            };
            Controls.Add(logBox);

            // 托盘
            trayMenu = new ContextMenuStrip();
            var itemShow = new ToolStripMenuItem("显示窗口");
            var itemOff = new ToolStripMenuItem("一键断网");
            var itemOn = new ToolStripMenuItem("一键联网");
            var itemExit = new ToolStripMenuItem("退出");
            itemShow.Click += (s, e) => { Show(); WindowState = FormWindowState.Normal; Activate(); };
            itemOff.Click += (s, e) => { var a = SelectedAdapter(); if (a != null) { SetAdapterState(a.Name, false); System.Threading.Thread.Sleep(600); RefreshAdapters(); } };
            itemOn.Click += (s, e) => { var a = SelectedAdapter(); if (a != null) { SetAdapterState(a.Name, true); System.Threading.Thread.Sleep(600); RefreshAdapters(); } };
            itemExit.Click += (s, e) => Close();
            trayMenu.Items.AddRange(new ToolStripItem[] { itemShow, itemOff, itemOn, itemExit });

            notifyIcon = new NotifyIcon
            {
                Icon = SystemIcons.Application,
                Text = "NetToggle",
                Visible = true,
                ContextMenuStrip = trayMenu
            };
            notifyIcon.DoubleClick += (s, e) => { Show(); WindowState = FormWindowState.Normal; Activate(); };

            Resize += (s, e) => { if (WindowState == FormWindowState.Minimized) Hide(); };
            FormClosing += (s, e) => { notifyIcon.Visible = false; if (bgTimer != null) bgTimer.Dispose(); };

            // 定时器：后台线程探测，避免阻塞 UI 线程导致界面卡死
            bgTimer = new System.Threading.Timer(BgTick, null, 2000, 2000);
        }

        private void BgTick(object state)
        {
            if (IsDisposed || !IsHandleCreated) return;
            bool online = TestOnline();

            // 更新 UI 必须切回主线程
            BeginInvoke((Action)(() =>
            {
                if (online)
                {
                    statusLabel.Text = "当前网络：● 已连接";
                    statusLabel.ForeColor = Color.FromArgb(20, 120, 40);
                    dot.BackColor = Color.FromArgb(40, 180, 70);
                }
                else
                {
                    statusLabel.Text = "当前网络：○ 已断开";
                    statusLabel.ForeColor = Color.FromArgb(190, 40, 40);
                    dot.BackColor = Color.FromArgb(220, 60, 60);
                }
            }));

            tickCount++;
            int guardEvery = Math.Max(1, (int)(numInterval.Value / 2));
            if (tickCount >= guardEvery)
            {
                tickCount = 0;
                if (chkWatch.Checked && !online)
                {
                    string name = Invoke((Func<string>)(() =>
                        adaptersListBox.SelectedItem != null
                            ? ((AdapterInfo)adaptersListBox.SelectedItem).Name
                            : null));
                    if (name != null)
                    {
                        Log($"自动守护：检测到离线，重连 [{name}]");
                        SetAdapterState(name, true);
                    }
                }
            }
        }

        private AdapterInfo SelectedAdapter()
        {
            if (adaptersListBox.SelectedItem == null)
            {
                Log("请先选择适配器");
                return null;
            }
            return (AdapterInfo)adaptersListBox.SelectedItem;
        }

        private void RefreshAdapters()
        {
            var list = new List<AdapterInfo>();
            try
            {
                using (var searcher = new ManagementObjectSearcher(
                    "SELECT NetConnectionID,NetEnabled FROM Win32_NetworkAdapter WHERE NetConnectionID IS NOT NULL"))
                {
                    foreach (ManagementObject mo in searcher.Get())
                    {
                        var name = mo["NetConnectionID"] as string;
                        if (string.IsNullOrWhiteSpace(name)) continue;
                        bool enabled = mo["NetEnabled"] != null && (bool)mo["NetEnabled"];
                        list.Add(new AdapterInfo
                        {
                            Name = name,
                            NetEnabled = enabled,
                            Status = enabled ? "已连接" : "已断开"
                        });
                    }
                }
            }
            catch (Exception ex)
            {
                Log("枚举适配器失败: " + ex.Message);
            }

            adaptersListBox.Items.Clear();
            foreach (var a in list) adaptersListBox.Items.Add(a);
            if (adaptersListBox.Items.Count > 0) adaptersListBox.SelectedIndex = 0;
            Log($"已刷新，共 {adaptersListBox.Items.Count} 个适配器");
        }

        private bool SetAdapterState(string name, bool enable)
        {
            if (string.IsNullOrWhiteSpace(name)) { Log("未选择适配器"); return false; }
            string admin = enable ? "enable" : "disable";
            string verb = enable ? "联网" : "断网";
            try
            {
                var psi = new ProcessStartInfo("netsh",
                    $"interface set interface \"{name}\" admin={admin}")
                {
                    CreateNoWindow = true,
                    UseShellExecute = false
                };
                using (var p = Process.Start(psi))
                {
                    p.WaitForExit();
                    if (p.ExitCode == 0)
                    {
                        Log($"已对 [{name}] 执行{verb}");
                        return true;
                    }
                    Log($"[{name}] {verb}失败，netsh 退出码 {p.ExitCode}");
                    return false;
                }
            }
            catch (Exception ex)
            {
                Log($"{verb}异常: " + ex.Message);
                return false;
            }
        }

        private bool TestOnline()
        {
            string[] hosts = { "223.5.5.5", "8.8.8.8", "119.29.29.29" };
            foreach (var h in hosts)
            {
                try
                {
                    using (var tcp = new TcpClient())
                    {
                        var ar = tcp.BeginConnect(h, 53, null, null);
                        if (ar.AsyncWaitHandle.WaitOne(1500, false)) return true;
                    }
                }
                catch { }
            }
            return false;
        }

        private void Log(string msg)
        {
            if (logBox == null) return;
            string line = $"{DateTime.Now:HH:mm:ss}  {msg}{Environment.NewLine}";
            if (logBox.InvokeRequired)
                logBox.BeginInvoke((Action)(() => logBox.AppendText(line)));
            else
                logBox.AppendText(line);
        }
    }
}
