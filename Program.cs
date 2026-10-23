using System;
using System.Diagnostics;
using System.Security.Principal;
using System.Windows.Forms;

namespace NetToggle
{
    static class Program
    {
        [STAThread]
        static void Main()
        {
            // 双保险：若清单未提权，则自行以 runas 重启
            if (!IsAdministrator())
            {
                try
                {
                    var psi = new ProcessStartInfo
                    {
                        FileName = Application.ExecutablePath,
                        UseShellExecute = true,
                        Verb = "runas"
                    };
                    Process.Start(psi);
                }
                catch
                {
                    MessageBox.Show("需要管理员权限才能切换网卡状态。", "NetToggle",
                        MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
                return;
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }

        static bool IsAdministrator()
        {
            var identity = WindowsIdentity.GetCurrent();
            var principal = new WindowsPrincipal(identity);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }
    }
}
