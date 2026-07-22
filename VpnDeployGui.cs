using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;

internal sealed class FieldSpec
{
    public string Key, Label, DefaultValue;
    public bool Secret, Required;
    public FieldSpec(string key, string label, string defaultValue, bool required, bool secret)
    { Key = key; Label = label; DefaultValue = defaultValue; Required = required; Secret = secret; }
}

internal sealed class InputDialog : Form
{
    readonly Dictionary<string, TextBox> boxes = new Dictionary<string, TextBox>();
    readonly List<FieldSpec> specs;
    public Dictionary<string, string> Values { get; private set; }

    public InputDialog(string title, string note, List<FieldSpec> fields)
    {
        specs = fields;
        Text = title;
        StartPosition = FormStartPosition.CenterParent;
        ClientSize = new Size(610, 650);
        MinimumSize = new Size(560, 520);
        Font = new Font("Segoe UI", 9F);
        MaximizeBox = false;
        MinimizeBox = false;

        var noteLabel = new Label { Text = note, AutoSize = false, Height = 48, Dock = DockStyle.Top, Padding = new Padding(12, 10, 12, 4) };
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 52, FlowDirection = FlowDirection.RightToLeft, Padding = new Padding(8) };
        var ok = new Button { Text = "開始部署", Width = 105, Height = 30 };
        var cancel = new Button { Text = "取消", Width = 90, Height = 30, DialogResult = DialogResult.Cancel };
        ok.Click += delegate { ValidateAndClose(); };
        buttons.Controls.Add(ok);
        buttons.Controls.Add(cancel);
        AcceptButton = ok;
        CancelButton = cancel;

        var table = new TableLayoutPanel { AutoSize = true, ColumnCount = 2, Dock = DockStyle.Top, Padding = new Padding(12), GrowStyle = TableLayoutPanelGrowStyle.AddRows };
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 190));
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        foreach (FieldSpec field in fields)
        {
            var label = new Label { Text = field.Label, AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(3, 8, 3, 8) };
            var box = new TextBox { Text = field.DefaultValue, Width = 350, Anchor = AnchorStyles.Left | AnchorStyles.Right, UseSystemPasswordChar = field.Secret, Margin = new Padding(3, 5, 3, 5) };
            boxes[field.Key] = box;
            table.Controls.Add(label);
            table.Controls.Add(box);
        }
        var scroll = new Panel { Dock = DockStyle.Fill, AutoScroll = true };
        scroll.Controls.Add(table);
        Controls.Add(scroll);
        Controls.Add(buttons);
        Controls.Add(noteLabel);
    }

    void ValidateAndClose()
    {
        var values = new Dictionary<string, string>();
        foreach (FieldSpec field in specs)
        {
            string value = boxes[field.Key].Text.Trim();
            if (field.Required && value.Length == 0)
            {
                MessageBox.Show(this, field.Label + " 不可空白。", "欄位未填", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                boxes[field.Key].Focus();
                return;
            }
            values[field.Key] = value;
        }
        Values = values;
        DialogResult = DialogResult.OK;
        Close();
    }
}

internal sealed class MainForm : Form
{
    readonly RichTextBox log = new RichTextBox();
    readonly Button linuxButton = new Button();
    readonly Button androidButton = new Button();
    readonly Button stopButton = new Button();
    readonly Label status = new Label();
    Process activeProcess;
    string workDir;

    public MainForm()
    {
        Text = "VpnDeploy - WireGuard GUI";
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(900, 650);
        MinimumSize = new Size(760, 520);
        Font = new Font("Segoe UI", 9F);

        var title = new Label { Text = "WireGuard Deployment", Font = new Font("Segoe UI", 16F, FontStyle.Bold), AutoSize = true, Location = new Point(18, 15) };
        var subtitle = new Label { Text = "選擇部署方式；所有連線與 VPN 欄位會在同一個視窗一次輸入。", AutoSize = true, Location = new Point(21, 50) };
        linuxButton.Text = "Linux Server + Linux Client";
        androidButton.Text = "Linux Server + Android Root Client";
        stopButton.Text = "停止";
        linuxButton.SetBounds(22, 82, 250, 45);
        androidButton.SetBounds(282, 82, 285, 45);
        stopButton.SetBounds(577, 82, 90, 45);
        stopButton.Enabled = false;
        linuxButton.Click += async delegate { await StartLinux(); };
        androidButton.Click += async delegate { await StartAndroid(); };
        stopButton.Click += delegate { StopDeployment(); };
        status.Text = "Ready";
        status.AutoSize = true;
        status.Location = new Point(685, 98);

        log.ReadOnly = true;
        log.BackColor = Color.FromArgb(24, 24, 24);
        log.ForeColor = Color.Gainsboro;
        log.Font = new Font("Consolas", 9F);
        log.WordWrap = false;
        log.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;
        log.SetBounds(18, 145, 864, 485);

        Controls.Add(title); Controls.Add(subtitle); Controls.Add(linuxButton); Controls.Add(androidButton);
        Controls.Add(stopButton); Controls.Add(status); Controls.Add(log);
        FormClosing += delegate { StopDeployment(); Cleanup(); };

        try
        {
            ExtractResources();
            Append("VpnDeploy GUI ready.\r\n");
        }
        catch (Exception ex)
        {
            Append("Launcher error: " + ex.Message + "\r\n");
            linuxButton.Enabled = androidButton.Enabled = false;
        }
    }

    async Task StartLinux()
    {
        var fields = new List<FieldSpec> {
            F("server_ip", "Server SSH IP", "", true), F("server_user", "Server SSH User", "p", true), P("server_password", "Server SSH Password", "p"),
            F("client_ip", "Client SSH IP", "", true), F("client_user", "Client SSH User", "p", true), P("client_password", "Client SSH Password", "p"),
            F("listen_port", "WireGuard Listen Port", "51820", true), F("vpn_network", "VPN Network", "10.66.66.0/24", true),
            F("server_cidr", "Server VPN CIDR", "10.66.66.1/24", true), F("client_cidr", "Client VPN CIDR", "10.66.66.2/32", true),
            F("endpoint", "Client Endpoint (空白自動)", "", false), F("wg_if", "WireGuard Interface", "wg0", true)
        };
        using (var dialog = new InputDialog("Linux Server + Linux Client", "此模式會部署／重新部署兩台 Linux 的 WireGuard 設定。IP 沒有安全的預設值，請填實際位址。", fields))
        {
            if (dialog.ShowDialog(this) != DialogResult.OK) return;
            var v = dialog.Values;
            if (!ValidateCommon(v["server_ip"], v["client_ip"], v["listen_port"])) return;
            string endpoint = v["endpoint"].Length == 0 ? v["server_ip"] + ":" + v["listen_port"] : v["endpoint"];
            if (!Confirm("Server: " + v["server_user"] + "@" + v["server_ip"] + " -> " + v["server_cidr"] + "\nClient: " + v["client_user"] + "@" + v["client_ip"] + " -> " + v["client_cidr"] + "\nEndpoint: " + endpoint + "\n\n確定開始部署？")) return;
            SetBusy(true);
            try
            {
                string serverKey = await ConfirmHostKey(v["server_ip"], 22, v["server_user"], v["server_password"]);
                string clientKey = await ConfirmHostKey(v["client_ip"], 22, v["client_user"], v["client_password"]);
                var args = new List<string> { "-Mode", "1", "-NonInteractive", "-ServerIp", v["server_ip"], "-ServerUser", v["server_user"], "-ServerPassword", v["server_password"], "-ClientIp", v["client_ip"], "-ClientUser", v["client_user"], "-ClientPassword", v["client_password"], "-ListenPort", v["listen_port"], "-VpnNetwork", v["vpn_network"], "-ServerVpnCidr", v["server_cidr"], "-ClientVpnCidr", v["client_cidr"], "-Endpoint", endpoint, "-WgIf", v["wg_if"] };
                if (serverKey.Length > 0) { args.Add("-ServerHostKey"); args.Add(serverKey); }
                if (clientKey.Length > 0) { args.Add("-ClientHostKey"); args.Add(clientKey); }
                await RunDeployment("VpnDeployCombined.ps1", args);
            }
            catch (Exception ex) { Fail(ex); }
            finally { SetBusy(false); }
        }
    }

    async Task StartAndroid()
    {
        var fields = new List<FieldSpec> {
            F("server_ip", "Server SSH IP", "", true), F("server_user", "Server SSH User", "pcp", true), P("server_password", "Server SSH Password", "pcp"),
            F("android_ip", "Android SSH IP", "", true), F("android_user", "Android SSH User", "root", true), P("android_password", "Android SSH Password", "p"), F("android_port", "Android SSH Port", "22", true),
            F("listen_port", "WireGuard Listen Port", "51820", true), F("vpn_network", "VPN Network", "10.66.66.0/24", true),
            F("server_cidr", "Server VPN CIDR", "10.66.66.1/24", true), F("android_cidr", "Android VPN CIDR", "10.66.66.3/32", true),
            F("endpoint", "Android Endpoint (空白自動)", "", false), F("allowed_ips", "Allowed IPs", "10.66.66.0/24", true),
            F("client_name", "Android Client Name", "android-root", true), F("wg_if", "WireGuard Interface", "wg0", true)
        };
        using (var dialog = new InputDialog("Linux Server + Android Root Client", "一次輸入 Ubuntu Server 與具 root SSH 的 Android 裝置資料。", fields))
        {
            if (dialog.ShowDialog(this) != DialogResult.OK) return;
            var v = dialog.Values;
            if (!ValidateCommon(v["server_ip"], v["android_ip"], v["listen_port"])) return;
            int androidPort;
            if (!int.TryParse(v["android_port"], out androidPort) || androidPort < 1 || androidPort > 65535) { Warn("Android SSH Port 必須是 1–65535。"); return; }
            string endpoint = v["endpoint"].Length == 0 ? v["server_ip"] + ":" + v["listen_port"] : v["endpoint"];
            if (!Confirm("Server: " + v["server_user"] + "@" + v["server_ip"] + " -> " + v["server_cidr"] + "\nAndroid: " + v["android_user"] + "@" + v["android_ip"] + ":" + androidPort + " -> " + v["android_cidr"] + "\nEndpoint: " + endpoint + "\n\n確定開始部署？")) return;
            SetBusy(true);
            try
            {
                string serverKey = await ConfirmHostKey(v["server_ip"], 22, v["server_user"], v["server_password"]);
                string androidKey = await ConfirmHostKey(v["android_ip"], androidPort, v["android_user"], v["android_password"]);
                var args = new List<string> { "-NonInteractive", "-ServerIp", v["server_ip"], "-ServerUser", v["server_user"], "-ServerPassword", v["server_password"], "-AndroidIp", v["android_ip"], "-AndroidUser", v["android_user"], "-AndroidPassword", v["android_password"], "-AndroidSshPort", v["android_port"], "-ListenPort", v["listen_port"], "-VpnNetwork", v["vpn_network"], "-ServerVpnCidr", v["server_cidr"], "-AndroidVpnCidr", v["android_cidr"], "-Endpoint", endpoint, "-AllowedIPs", v["allowed_ips"], "-ClientName", v["client_name"], "-WgIf", v["wg_if"], "-AndroidWgBinary", Path.Combine(workDir, "android-bin", "wg-arm64") };
                if (serverKey.Length > 0) { args.Add("-ServerHostKey"); args.Add(serverKey); }
                if (androidKey.Length > 0) { args.Add("-AndroidHostKey"); args.Add(androidKey); }
                await RunDeployment("VpnDeployAndroid.ps1", args);
            }
            catch (Exception ex) { Fail(ex); }
            finally { SetBusy(false); }
        }
    }

    async Task<string> ConfirmHostKey(string ip, int port, string user, string password)
    {
        Append("Checking SSH host key: " + user + "@" + ip + ":" + port + "\r\n");
        string output = await RunCapture(Path.Combine(workDir, "plink.exe"), new List<string> { "-batch", "-v", "-ssh", "-P", port.ToString(), "-l", user, "-pw", password, ip, "echo __VPNDEPLOY_SSH_OK__" });
        Match match = Regex.Match(output, "SHA256:[A-Za-z0-9+/=]+");
        if (output.Contains("__VPNDEPLOY_SSH_OK__")) { Append("SSH pre-check: PASS\r\n"); return match.Success ? match.Value : ""; }
        if (!match.Success) throw new Exception("SSH pre-check failed for " + ip + ":" + port + "\r\n" + ShortText(output));
        string fingerprint = match.Value;
        var answer = MessageBox.Show(this, "SSH 主機金鑰需要確認：\n\nHost: " + ip + ":" + port + "\nFingerprint: " + fingerprint + "\n\n請確認這是正確裝置。若 IP 曾重灌或更換設備，金鑰可能改變。是否信任並繼續？", "Confirm SSH Host Key", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
        if (answer != DialogResult.Yes) throw new OperationCanceledException("使用者取消 SSH 主機金鑰確認。");
        Append("SSH host key accepted: " + fingerprint + "\r\n");
        return fingerprint;
    }

    async Task RunDeployment(string scriptName, List<string> args)
    {
        Append("\r\n========== Deployment started " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " ==========\r\n");
        var all = new List<string> { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(workDir, scriptName) };
        all.AddRange(args);
        var psi = MakePsi("powershell.exe", all);
        psi.EnvironmentVariables["PATH"] = workDir + ";" + psi.EnvironmentVariables["PATH"];
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        activeProcess = new Process { StartInfo = psi, EnableRaisingEvents = true };
        activeProcess.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) Append(e.Data + "\r\n"); };
        activeProcess.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) Append("ERROR: " + e.Data + "\r\n"); };
        activeProcess.Start();
        activeProcess.BeginOutputReadLine();
        activeProcess.BeginErrorReadLine();
        await Task.Run(delegate { activeProcess.WaitForExit(); });
        int code = activeProcess.ExitCode;
        activeProcess.Dispose(); activeProcess = null;
        Append("========== " + (code == 0 ? "PASS" : "FAIL") + " (exit code " + code + ") ==========\r\n");
        status.Text = code == 0 ? "PASS" : "FAIL";
        status.ForeColor = code == 0 ? Color.DarkGreen : Color.DarkRed;
        MessageBox.Show(this, code == 0 ? "部署完成。" : "部署失敗，請查看下方 Log。", "VpnDeploy", MessageBoxButtons.OK, code == 0 ? MessageBoxIcon.Information : MessageBoxIcon.Error);
    }

    static async Task<string> RunCapture(string fileName, List<string> args)
    {
        var psi = MakePsi(fileName, args);
        psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
        using (var p = Process.Start(psi))
        {
            Task<string> stdout = p.StandardOutput.ReadToEndAsync();
            Task<string> stderr = p.StandardError.ReadToEndAsync();
            await Task.Run(delegate { p.WaitForExit(); });
            return (await stdout) + "\r\n" + (await stderr);
        }
    }

    static ProcessStartInfo MakePsi(string fileName, List<string> args)
    {
        var b = new StringBuilder();
        foreach (string arg in args) { if (b.Length > 0) b.Append(' '); b.Append(QuoteArg(arg)); }
        string directory = Path.GetDirectoryName(fileName);
        return new ProcessStartInfo { FileName = fileName, Arguments = b.ToString(), UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = string.IsNullOrEmpty(directory) ? Environment.CurrentDirectory : directory };
    }

    static string QuoteArg(string value)
    {
        if (value == null || value.Length == 0) return "\"\"";
        if (!Regex.IsMatch(value, "[\\s\\\"]")) return value;
        var b = new StringBuilder("\""); int slashes = 0;
        foreach (char c in value)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { b.Append('\\', slashes * 2 + 1); b.Append('"'); slashes = 0; continue; }
            b.Append('\\', slashes); slashes = 0; b.Append(c);
        }
        b.Append('\\', slashes * 2); b.Append('"'); return b.ToString();
    }

    void ExtractResources()
    {
        workDir = Path.Combine(Path.GetTempPath(), "VpnDeployGui-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(workDir); Directory.CreateDirectory(Path.Combine(workDir, "android-bin"));
        Extract("VpnDeployCombined.ps1", Path.Combine(workDir, "VpnDeployCombined.ps1"));
        Extract("VpnDeployAndroid.ps1", Path.Combine(workDir, "VpnDeployAndroid.ps1"));
        Extract("wireguard_check_start.sh", Path.Combine(workDir, "wireguard_check_start.sh"));
        Extract("plink.exe", Path.Combine(workDir, "plink.exe")); Extract("pscp.exe", Path.Combine(workDir, "pscp.exe"));
        Extract("wg-arm64", Path.Combine(workDir, "android-bin", "wg-arm64"));
    }

    static void Extract(string resourceName, string target)
    {
        using (Stream input = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName))
        {
            if (input == null) throw new Exception("Embedded resource missing: " + resourceName);
            using (var output = File.Create(target)) input.CopyTo(output);
        }
    }

    void StopDeployment()
    {
        try { if (activeProcess != null && !activeProcess.HasExited) { activeProcess.Kill(); Append("Deployment stopped by user.\r\n"); } } catch { }
    }
    void Cleanup() { try { if (!string.IsNullOrEmpty(workDir) && Directory.Exists(workDir)) Directory.Delete(workDir, true); } catch { } }
    void SetBusy(bool busy) { linuxButton.Enabled = androidButton.Enabled = !busy; stopButton.Enabled = busy; status.Text = busy ? "Running..." : (status.Text == "Running..." ? "Ready" : status.Text); if (busy) status.ForeColor = Color.DarkOrange; }
    void Append(string text) { if (InvokeRequired) { BeginInvoke(new Action<string>(Append), text); return; } log.AppendText(text); log.SelectionStart = log.TextLength; log.ScrollToCaret(); }
    void Fail(Exception ex) { Append("FAIL: " + ex.Message + "\r\n"); status.Text = "FAIL"; status.ForeColor = Color.DarkRed; if (!(ex is OperationCanceledException)) MessageBox.Show(this, ex.Message, "VpnDeploy", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    bool ValidateCommon(string serverIp, string clientIp, string port) { if (!ValidIp(serverIp) || !ValidIp(clientIp)) { Warn("請輸入正確的 IPv4 位址。"); return false; } if (serverIp == clientIp) { Warn("Server 與 Client IP 不可相同。"); return false; } int p; if (!int.TryParse(port, out p) || p < 1 || p > 65535) { Warn("WireGuard Listen Port 必須是 1–65535。"); return false; } return true; }
    static bool ValidIp(string value) { System.Net.IPAddress ip; return System.Net.IPAddress.TryParse(value, out ip) && ip.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork; }
    bool Confirm(string text) { return MessageBox.Show(this, text, "確認部署", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes; }
    void Warn(string text) { MessageBox.Show(this, text, "輸入錯誤", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
    static string ShortText(string s) { s = (s ?? "").Trim(); return s.Length > 1200 ? s.Substring(0, 1200) + "..." : s; }
    static FieldSpec F(string key, string label, string value, bool required) { return new FieldSpec(key, label, value, required, false); }
    static FieldSpec P(string key, string label, string value) { return new FieldSpec(key, label, value, true, true); }
}

internal static class Program
{
    [STAThread]
    static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new MainForm());
    }
}
