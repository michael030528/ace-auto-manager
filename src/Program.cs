using System;
using System.IO;
using System.Text;
using System.Linq;
using System.Drawing;
using System.Diagnostics;
using System.Reflection;
using System.Collections.Generic;
using System.Security.Principal;
using System.Security.AccessControl;
using System.Threading.Tasks;
using System.Windows.Forms;
using System.Web.Script.Serialization;
using Microsoft.Win32;

[assembly: AssemblyTitle("ACE 自动管理")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]

namespace AceAutoManager {
    public class Settings {
        public int version = 2;
        public string userSid;
        public int graceSeconds = 45;
        public int pollSeconds = 5;
        public bool closeOnLogin = true;
        public string[] sessionExecutables = new string[0];
        public string[] blockerExecutables = new string[0];
        public string[] gameDirectories = new string[0];
    }
    static class Program {
        internal static JavaScriptSerializer Json = new JavaScriptSerializer();
        internal static int CountItems(object value) { var items=value as System.Collections.ICollection; return items==null?0:items.Count; }
        internal static string Data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "AceGameAutoClose");
        internal static string Install = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "AceGameAutoClose");
        internal static string PowerShell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe");
        internal static string Quote(string s) { return "\"" + s.Replace("\"", "\\\"") + "\""; }
        internal static string Payload(string name) {
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name)) {
                if (stream == null) throw new IOException("缺少内置资源：" + name);
                using (var reader = new StreamReader(stream, Encoding.UTF8)) return reader.ReadToEnd();
            }
        }
        internal static void ScheduleLauncherRemoval() {
            string path=Application.ExecutablePath, hash;
            using(var sha=System.Security.Cryptography.SHA256.Create())
            using(var file=File.OpenRead(path)) { hash=BitConverter.ToString(sha.ComputeHash(file)).Replace("-",""); }
            string script=Payload("Remove-Launcher.ps1").Replace("__TARGET_BASE64__",Convert.ToBase64String(Encoding.Unicode.GetBytes(path))).Replace("__EXPECTED_HASH__",hash);
            var info=new ProcessStartInfo(PowerShell,"-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand "+Convert.ToBase64String(Encoding.Unicode.GetBytes(script))){UseShellExecute=false,CreateNoWindow=true};
            using(var process=Process.Start(info)) { if(process==null)throw new IOException("无法启动 EXE 删除程序。后台任务已卸载，请手动删除 EXE。"); }
        }
        // 管理员临时目录也限制为管理员和 SYSTEM 可写。
        internal static string Extract(bool protect) {
            string dir = Path.Combine(Path.GetTempPath(), "AceManager-" + Guid.NewGuid().ToString("N"));
            if (protect) {
                var acl = new DirectorySecurity();
                acl.SetAccessRuleProtection(true, false);
                foreach (string sid in new [] {"S-1-5-18", "S-1-5-32-544"})
                    acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid), FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
                acl.SetOwner(new SecurityIdentifier("S-1-5-32-544"));
                Directory.CreateDirectory(dir, acl);
            } else Directory.CreateDirectory(dir);
            foreach (string name in new [] {"Backend.ps1", "Monitor-Ace.ps1", "Discover-AceGames.ps1"}) File.WriteAllText(Path.Combine(dir,name),Payload(name),new UTF8Encoding(true));
            return dir;
        }
        internal static string RunBackend(string dir, string mode, string request) {
            var info = new ProcessStartInfo(PowerShell, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(Path.Combine(dir,"Backend.ps1")) + " -Mode " + mode + (request == null ? "" : " -RequestPath " + Quote(request)));
            info.UseShellExecute = false; info.CreateNoWindow = true; info.RedirectStandardOutput = true; info.RedirectStandardError = true;
            info.StandardOutputEncoding = Encoding.UTF8; info.StandardErrorEncoding = Encoding.UTF8;
            using (var p = Process.Start(info)) {
                Task<string> output = p.StandardOutput.ReadToEndAsync(), error = p.StandardError.ReadToEndAsync();
                if (!p.WaitForExit(120000)) { p.Kill(); throw new Exception("操作超时。请查看日志；后台任务状态需要重新核验。"); }
                Task.WaitAll(output,error);
                string text = output.Result.Trim();
                if (text.Length == 0) throw new Exception(error.Result.Length > 0 ? error.Result : "未收到操作结果。");
                return text;
            }
        }
        // 只删除自己创建的临时目录里的已知文件，不递归遍历。
        internal static void Clean(string dir) {
            if (dir == null) return;
            try { foreach (string f in new [] {"Backend.ps1","Monitor-Ace.ps1","Discover-AceGames.ps1","config.json"}) { string p=Path.Combine(dir,f); if(File.Exists(p)) File.Delete(p); } if(Directory.GetFileSystemEntries(dir).Length==0) Directory.Delete(dir); } catch {}
        }
        [STAThread] static int Main(string[] args) {
            if (args.Length == 3 && args[0] == "--admin") {
                string dir = null;
                try {
                    if (!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)) throw new Exception("未获得管理员权限。");
                    if (!new [] {"Install","Pause","Remove","Clean"}.Contains(args[1])) throw new Exception("无效操作。");
                    dir = Extract(true);
                    var result = Json.Deserialize<Dictionary<string,object>>(RunBackend(dir,args[1],args[2]));
                    bool ok = result.ContainsKey("ok") && (bool)result["ok"];
                    if(ok && args[1]=="Remove") ScheduleLauncherRemoval();
                    if (!ok) MessageBox.Show(Convert.ToString(result["message"]),"操作未完成",MessageBoxButtons.OK,MessageBoxIcon.Warning);
                    return ok ? 0 : 1;
                } catch(Exception e) { MessageBox.Show(e.Message,"操作未完成",MessageBoxButtons.OK,MessageBoxIcon.Error); return 1; }
                finally { Clean(dir); }
            }
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
            if (args.Length == 1 && args[0] == "--self-test") {
                try {
                    if (!Payload("Monitor-Ace.ps1").Contains("System.ServiceProcess")) return 2;
                    if (!Payload("Backend.ps1").Contains("Assert-Protected")) return 3;
                    var sample=Json.Deserialize<Dictionary<string,object>>("{\"items\":[{},{}]}");
                    if(CountItems(sample["items"])!=2) return 5;
                    using(var f = new MainForm(true)) { f.CreateControl(); if (f.ClientSize.Width < 800) return 4; }
                    return 0;
                } catch { return 1; }
            }
            using (var form = new MainForm(false)) {
                if(args.Length==2 && args[0]=="--preview") {
                    var capture = new Timer { Interval=20000 };
                    capture.Tick += (s,e) => { capture.Stop(); using(var bmp = new Bitmap(form.Width,form.Height)) { form.DrawToBitmap(bmp,new Rectangle(0,0,form.Width,form.Height)); bmp.Save(args[1]); } form.Close(); };
                    form.Shown += (s,e) => capture.Start();
                }
                Application.Run(form);
            }
            return 0;
        }
    }
    public class MainForm : Form {
        readonly Color blue = Color.FromArgb(32,91,224);
        Label manager, ace, activity, feedback;
        Button enable, pause, remove, detect, add, drop, clean, details;
        string componentDetails="尚未读取组件状态。";
        CheckBox login;
        NumericUpDown delay;
        ListBox games;
        Timer refresh;
        bool busy, checking, closed, discovering;
        HashSet<string> gameRoots = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        string runtime;
        Settings settings = new Settings();

        public MainForm(bool test) {
            Text="ACE 自动管理 · v1.1.0"; ClientSize=new Size(900,740); MinimumSize=new Size(916,779); MaximumSize=new Size(916,779);
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("app.ico"))
            using (var icon = new Icon(stream)) { Icon = (Icon)icon.Clone(); }
            AutoScaleMode=AutoScaleMode.None; Font=new Font("Microsoft YaHei UI",10F); BackColor=Color.FromArgb(245,247,251); StartPosition=FormStartPosition.CenterScreen;
            var title = LabelAt("让 ACE 随游戏工作",30,23,800,40,23,true); title.ForeColor=Color.FromArgb(22,34,55);
            LabelAt("玩游戏时照常开启 · 不玩时自动清理 · 关闭窗口也能继续管理",33,70,835,27,10,false);
            var card = new Panel { Bounds=new Rectangle(30,115,840,110),BackColor=Color.White }; Controls.Add(card);
            manager = LabelIn(card,"自动管理：正在检查…",20,15,790,25,12,true);
            ace = LabelIn(card,"ACE 状态：正在读取…",20,47,790,24,10,false);
            activity = LabelIn(card,"",20,77,790,23,9,false);
            enable=ButtonAt("一键开启自动管理",30,244,310,48); enable.BackColor=blue; enable.ForeColor=Color.White;
            pause=ButtonAt("暂停自动管理",355,244,175,48);
            remove=ButtonAt("卸载自动管理",545,244,175,48);
            var status=ButtonAt("刷新状态",735,244,135,48);
            enable.Click += async(s,e)=>await Manage("Install"); pause.Click += async(s,e)=>await Manage("Pause");
            remove.Click += async(s,e)=> { if(MessageBox.Show("卸载后台任务，关闭此窗口，并删除当前运行的 EXE？\nACE 本体不会被卸载，配置和日志保留，其他位置的 EXE 副本不会删除。","卸载自动管理",MessageBoxButtons.YesNo,MessageBoxIcon.Question)==DialogResult.Yes) await Manage("Remove"); };
            status.Click += async(s,e)=>await RefreshStatus();
            login=new CheckBox {Text="登录电脑后，无游戏运行时也自动清理",Bounds=new Rectangle(33,309,460,29),Checked=true}; Controls.Add(login);
            LabelAt("退出游戏后等待",520,310,135,27,10,false);
            delay=new NumericUpDown {Bounds=new Rectangle(660,309,80,29),Minimum=15,Maximum=300,Value=45}; Controls.Add(delay); LabelAt("秒再关闭 ACE",750,310,125,27,10,false);
            LabelAt("需要保护的游戏",30,355,400,27,12,true);
            LabelAt("根据本机 ACE 组件自动识别；同目录相关进程也会保护。安装前请确认名单完整。",30,385,830,24,9,false);
            games=new ListBox {Bounds=new Rectangle(30,416,650,120),HorizontalScrollbar=true,BorderStyle=BorderStyle.FixedSingle,BackColor=Color.White,ItemHeight=23}; Controls.Add(games);
            games.FormattingEnabled=true;
            games.Format+=(s,e)=>{string n=Path.GetFileName(Convert.ToString(e.ListItem));e.Value=n=="VALORANT-Win64-Shipping.exe"?"无畏契约":n=="LeagueClient.exe"?"英雄联盟 · 客户端":n=="League of Legends.exe"?"英雄联盟 · 对局进程":n=="TFTTencentClient-Win64-Shipping.exe"?"云顶之弈客户端":n;};
            detect=ButtonAt("自动识别游戏",695,416,175,33); add=ButtonAt("添加游戏程序",695,459,175,33); drop=ButtonAt("移除选中项",695,502,175,33);
            detect.Click+=async(s,e)=>await DiscoverGames();
            add.Click+=(s,e)=>{using(var dialog=new OpenFileDialog {Title="选择需要 ACE 的游戏主程序（不要选择反作弊程序）",Filter="游戏程序 (*.exe)|*.exe"}) {if(dialog.ShowDialog()==DialogResult.OK) {string name=Path.GetFileName(dialog.FileName);if(name.StartsWith("ACE-",StringComparison.OrdinalIgnoreCase)||name.StartsWith("SGuard",StringComparison.OrdinalIgnoreCase)) {MessageBox.Show("请选择游戏主程序，而不是 ACE 组件。");return;}AddGame(dialog.FileName);gameRoots.Add(Path.GetDirectoryName(dialog.FileName));}}};
            drop.Click+=(s,e)=>{if(games.SelectedIndex>=0) games.Items.RemoveAt(games.SelectedIndex);};
            feedback=LabelAt("",30,549,840,38,10,false); feedback.ForeColor=blue;
            LabelAt("安装和暂停需要 Windows 管理员授权。程序不会强制卸载驱动，也不会自动重启电脑。",30,596,840,23,9,false);
            var log=ButtonAt("查看运行日志",30,633,160,32);
            log.Click+=(s,e)=>{string p=Path.Combine(Program.Data,"monitor.log");if(File.Exists(p)) Process.Start(new ProcessStartInfo("notepad.exe",Program.Quote(p)));else MessageBox.Show("暂时没有日志。");};
            LabelAt("Windows 10 / 11 · 非 ACE 官方工具",575,638,300,24,9,false);
            clean=ButtonAt("立即清理 ACE",205,633,170,32);
            details=ButtonAt("残留组件详情",390,633,170,32);
            clean.Click+=async(s,e)=>await Manage("Clean");
            details.Click+=async(s,e)=>{await RefreshStatus();if(!closed)MessageBox.Show(componentDetails,"ACE 残留组件 · 实时查询",MessageBoxButtons.OK,MessageBoxIcon.Information);};
            LabelAt("清理失败最多自动重试 3 次，每次至少间隔 60 秒；检测到游戏会取消重试。",30,690,840,27,10,false);
            LoadSettings();
            if (!test) {
                runtime=Program.Extract(false);
                refresh=new Timer {Interval=10000}; refresh.Tick+=async(s,e)=>await RefreshStatus();
                Shown+=async(s,e)=>{await RefreshStatus();if(closed)return;await DiscoverGames();if(!closed)refresh.Start();};
            }
            FormClosing+=(s,e)=>{if(busy) {e.Cancel=true;feedback.Text="正在完成操作，请稍候再关闭窗口。";}};
            FormClosed+=(s,e)=>{closed=true;if(refresh!=null)refresh.Stop();if(!checking&&!discovering)Program.Clean(runtime);};
        }
        Label LabelAt(string text,int x,int y,int w,int h,float size,bool bold) {var l=new Label {Text=text,Bounds=new Rectangle(x,y,w,h),Font=new Font("Microsoft YaHei UI",size,bold?FontStyle.Bold:FontStyle.Regular),ForeColor=Color.FromArgb(76,88,106)};Controls.Add(l);return l;}
        Label LabelIn(Control p,string text,int x,int y,int w,int h,float size,bool bold) {var l=LabelAt(text,x,y,w,h,size,bold);Controls.Remove(l);p.Controls.Add(l);return l;}
        Button ButtonAt(string text,int x,int y,int w,int h) {var b=new Button {Text=text,Bounds=new Rectangle(x,y,w,h),FlatStyle=FlatStyle.Flat,BackColor=Color.White,Cursor=Cursors.Hand};b.FlatAppearance.BorderColor=Color.FromArgb(213,220,232);Controls.Add(b);return b;}
        void AddGame(string path) { if(File.Exists(path) && !games.Items.Cast<string>().Contains(path,StringComparer.OrdinalIgnoreCase))games.Items.Add(Path.GetFullPath(path)); }
        void LoadSettings() {
            try { string p=Path.Combine(Program.Install,"config.json"); if(File.Exists(p)) {settings=Program.Json.Deserialize<Settings>(File.ReadAllText(p));delay.Value=Math.Max(15,Math.Min(300,settings.graceSeconds));login.Checked=settings.closeOnLogin;foreach(string exe in settings.sessionExecutables)AddGame(exe);foreach(string root in settings.gameDirectories??new string[0])if(Directory.Exists(root))gameRoots.Add(root);} } catch {}
        }
        static string[] Strings(object value) {var seq=value as System.Collections.IEnumerable;return seq==null?new string[0]:seq.Cast<object>().Select(Convert.ToString).ToArray();}
        async Task DiscoverGames() {
            if(discovering||closed||runtime==null||busy)return;
            discovering=true;enable.Enabled=false;detect.Enabled=false;add.Enabled=false;drop.Enabled=false;
            feedback.Text="正在扫描安装记录、WeGame 和 Steam 游戏目录，核对 ACE 组件…";
            try {
                string output=await Task.Run(()=>Program.RunBackend(runtime,"Discover",null));if(closed)return;
                var result=Program.Json.Deserialize<Dictionary<string,object>>(output);if(!(bool)result["ok"])throw new Exception(Convert.ToString(result["message"]));
                var discovery=(Dictionary<string,object>)result["discovery"];
                var found=Strings(discovery["sessionExecutables"]);foreach(string path in found)AddGame(path);
                foreach(string root in Strings(discovery["gameDirectories"]))gameRoots.Add(root);
                int unresolved=Convert.ToInt32(discovery["unresolved"]);
                feedback.Text="已根据 ACE 组件自动发现 "+found.Length+" 个游戏进程。"+(unresolved>0?"有 "+unresolved+" 处组件未能关联主程序，请手动补充。":"请确认名单后点击“一键开启自动管理”。");
            }catch(Exception e){if(!closed)feedback.Text="自动识别未完成："+e.Message+" 可手动添加游戏。";}
            finally {discovering=false;if(!closed){enable.Enabled=true;detect.Enabled=true;add.Enabled=true;drop.Enabled=true;}else if(!checking)Program.Clean(runtime);}
        }
        Settings MakeSettings() {
            var c = new Settings {userSid=WindowsIdentity.GetCurrent().User.Value,graceSeconds=(int)delay.Value,closeOnLogin=login.Checked,sessionExecutables=games.Items.Cast<string>().ToArray()};
            var blockers=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach(string exe in c.sessionExecutables) {
                string folder=Path.GetDirectoryName(exe), name=Path.GetFileName(exe);
                if(name.Equals("VALORANT-Win64-Shipping.exe",StringComparison.OrdinalIgnoreCase)) { string root=Path.GetFullPath(Path.Combine(folder,@"..\..\.."));blockers.Add(Path.Combine(root,"VALORANT.exe")); }
                if(name.Equals("LeagueClient.exe",StringComparison.OrdinalIgnoreCase)) {blockers.Add(Path.Combine(folder,"LeagueClientUx.exe"));string root=Directory.GetParent(folder).FullName;blockers.Add(Path.Combine(root,@"Launcher\Client.exe"));blockers.Add(Path.Combine(root,@"TCLS\client.exe"));}
                if(name.Equals("League of Legends.exe",StringComparison.OrdinalIgnoreCase)) {string root=Directory.GetParent(folder).FullName;blockers.Add(Path.Combine(root,@"LeagueClient\LeagueClient.exe"));blockers.Add(Path.Combine(root,@"LeagueClient\LeagueClientUx.exe"));}
                if(name.Equals("TFTTencentClient-Win64-Shipping.exe",StringComparison.OrdinalIgnoreCase))blockers.Add(Path.GetFullPath(Path.Combine(folder,@"..\..\..\TFTTencentClient.exe")));
            }
            c.blockerExecutables=blockers.Where(File.Exists).ToArray();c.gameDirectories=gameRoots.Where(r=>c.sessionExecutables.Any(p=>p.StartsWith(r.TrimEnd('\\')+"\\",StringComparison.OrdinalIgnoreCase))).ToArray();return c;
        }
        async Task Manage(string mode) {
            if(busy||discovering)return;
            if(mode=="Install" && games.Items.Count==0) {MessageBox.Show("还没有识别到游戏。请先点击“自动识别游戏”，或手动添加游戏主程序。");return;}
            busy=true;foreach(var b in new[]{enable,pause,remove,detect,add,drop,clean})b.Enabled=false;
            feedback.Text="请完成 Windows 管理员授权，操作正在进行…";
            string request=Path.Combine(Path.GetTempPath(),"AceManager-request-"+Guid.NewGuid().ToString("N")+".json");
            try {
                File.WriteAllText(request,Program.Json.Serialize(MakeSettings()),new UTF8Encoding(true));
                int code=await Task.Run(()=>{var info=new ProcessStartInfo(Application.ExecutablePath,"--admin "+mode+" "+Program.Quote(request)){UseShellExecute=true,Verb="runas",WindowStyle=ProcessWindowStyle.Hidden};using(var p=Process.Start(info)){p.WaitForExit();return p.ExitCode;}});
                feedback.Text=code==0 ? (mode=="Install"?"已开启自动管理，关闭窗口后仍会继续工作。":mode=="Clean"?"清理请求已提交；后台会先检查游戏，请稍后刷新状态。":"自动管理已停止。") : "操作未完成；请查看弹窗信息后重试。";
                if(code==0 && mode=="Remove") {busy=false;Close();return;}
            } catch(System.ComponentModel.Win32Exception e) {feedback.Text=e.NativeErrorCode==1223?"管理员授权已取消，设置未更改。":e.Message;}
            catch(Exception e) {feedback.Text="操作未完成："+e.Message;}
            finally {try{File.Delete(request);}catch{}busy=false;if(!closed)foreach(var b in new[]{enable,pause,remove,detect,add,drop,clean})b.Enabled=true;}
            await RefreshStatus();
        }
        async Task RefreshStatus() {
            if(checking||closed||runtime==null)return;checking=true;
            try {
                string output=await Task.Run(()=>Program.RunBackend(runtime,"Status",null));
                if(closed)return;
                var d=Program.Json.Deserialize<Dictionary<string,object>>(output);
                if(!(bool)d["ok"])throw new Exception(Convert.ToString(d["message"]));
                bool installed=(bool)d["installed"],alive=(bool)d["monitorAlive"];
                enable.Text="一键开启自动管理";
                manager.Text=alive?"自动管理：后台运行中":(installed?"自动管理：已安装，可一键开启":"自动管理：尚未安装");manager.ForeColor=alive?Color.FromArgb(12,125,91):Color.FromArgb(76,88,106);
                int count=Program.CountItems(d["drivers"])+Program.CountItems(d["services"])+Program.CountItems(d["processes"]);
                ace.Text=count>0?"ACE：检测到 "+count+" 个运行中的组件":"ACE：未检测到运行中的组件";
                var st=d["status"] as Dictionary<string,object>;
                var detailText=new StringBuilder("查询时间："+DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")+"\r\n");
                foreach(string group in new[]{"drivers","services","processes"}) {
                    detailText.AppendLine("\r\n"+(group=="drivers"?"驱动":group=="services"?"服务":"进程")+"：");
                    var items=d[group] as System.Collections.IEnumerable;
                    if(Program.CountItems(d[group])==0)detailText.AppendLine("未检测到运行中的组件");
                    if(items!=null)foreach(object item in items) {var row=item as Dictionary<string,object>;if(row!=null)detailText.AppendLine(Convert.ToString(row["Name"])+"  ·  "+(row.ContainsKey("State")?Convert.ToString(row["State"]):"PID "+Convert.ToString(row["ProcessId"])));}
                }
                if(st!=null && st.ContainsKey("detail"))detailText.AppendLine("\r\n最近记录："+Convert.ToString(st["detail"]));
                componentDetails=detailText.ToString();
                var words=new Dictionary<string,string>{{"Startup","正在准备登录后检查"},{"Idle","等待游戏启动"},{"Active","游戏或客户端运行中，暂不关闭"},{"Waiting","等待连续无游戏时段"},{"Closed","最近一次清理已完成"},{"Partial","仍有组件未关闭，请查看日志"},{"Attention","检测或关闭遇到问题，请查看日志"},{"Paused","已暂停"},{"Removed","自动任务已移除"}};
                string state=st!=null&&st.ContainsKey("state")?Convert.ToString(st["state"]):"";
                words["Retrying"]="清理未完成，等待自动重试（最多 3 次）"; words["Blocked"]="检测到游戏或客户端，已取消立即清理";
                words["Cleaning"]="正在清理 ACE，完成后将核验残留组件";
                words["RetryExhausted"]="已达 3 次重试上限，请查看残留组件和日志";
                activity.Text=st==null?"点击“一键开启自动管理”开始使用。":"最近记录："+(words.ContainsKey(state)?words[state]:state)+(st.ContainsKey("updatedAt")?"  ·  "+Convert.ToString(st["updatedAt"]):"");
            }catch(Exception e){if(!closed){manager.Text="状态读取失败";activity.Text=e.Message;componentDetails="实时查询失败，不能据此判断 ACE 已关闭。\r\n"+e.Message;}}
            finally {checking=false;if(closed&&!discovering)Program.Clean(runtime);}
        }
    }
}
