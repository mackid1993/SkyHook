using System;
using System.Drawing;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
using Hardcodet.Wpf.TaskbarNotification;
using SkyHook.Services;

namespace SkyHook;

public partial class App : Application
{
    private Mutex? _mutex;
    private TaskbarIcon? _trayIcon;
    private Views.TrayPopup? _trayPopup;
    private DispatcherTimer? _trayTimer;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // Single instance
        _mutex = new Mutex(true, "SkyHook_SingleInstance", out bool created);
        if (!created)
        {
            MessageBox.Show("SkyHook is already running.", "SkyHook", MessageBoxButton.OK);
            Shutdown();
            return;
        }

        // Initialize services
        _ = RcloneService.Instance;
        _ = WinFspService.Instance;

        // System tray icon
        _trayIcon = new TaskbarIcon
        {
            ToolTipText = "SkyHook",
            Icon = GetAppIcon(),
            MenuActivation = PopupActivationMode.RightClick,
            ContextMenu = CreateContextMenu()
        };
        _trayIcon.TrayMouseDoubleClick += (_, _) => OpenConfigWindow();
        _trayIcon.TrayLeftMouseUp += (_, _) => ShowTrayPopup();

        // Update tray icon based on mount state
        _trayTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        _trayTimer.Tick += (_, _) =>
        {
            bool hasMounted = RcloneService.Instance.MountedCount > 0;
            _trayIcon.Icon = GetAppIcon();
            _trayIcon.ToolTipText = hasMounted
                ? $"SkyHook — {RcloneService.Instance.MountedCount} mounted"
                : "SkyHook";
        };
        _trayTimer.Start();

        // Run setup
        Task.Run(async () =>
        {
            await RcloneService.Instance.Setup();
        });
    }

    private void ShowTrayPopup()
    {
        if (_trayPopup != null && _trayPopup.IsVisible)
        {
            _trayPopup.Hide();
            return;
        }

        _trayPopup = new Views.TrayPopup();
        _trayPopup.Deactivated += (_, _) => _trayPopup.Hide();

        // Position near tray
        var workArea = SystemParameters.WorkArea;
        _trayPopup.Left = workArea.Right - _trayPopup.Width - 8;
        _trayPopup.Top = workArea.Bottom - _trayPopup.Height - 8;

        _trayPopup.Show();
        _trayPopup.Activate();
    }

    public void OpenConfigWindow()
    {
        var existing = Current.Windows.OfType<Views.ConfigWindow>().FirstOrDefault();
        if (existing != null)
        {
            existing.Activate();
            return;
        }
        var window = new Views.ConfigWindow();
        window.Show();
    }

    private System.Windows.Controls.ContextMenu CreateContextMenu()
    {
        var menu = new System.Windows.Controls.ContextMenu();
        var settings = new System.Windows.Controls.MenuItem { Header = "Settings..." };
        settings.Click += (_, _) => OpenConfigWindow();
        menu.Items.Add(settings);
        menu.Items.Add(new System.Windows.Controls.Separator());
        var quit = new System.Windows.Controls.MenuItem { Header = "Quit" };
        quit.Click += (_, _) =>
        {
            Task.Run(async () => await RcloneService.Instance.Cleanup()).Wait(TimeSpan.FromSeconds(5));
            Shutdown();
        };
        menu.Items.Add(quit);
        return menu;
    }

    private static Icon? _appIcon;

    private static Icon GetAppIcon()
    {
        if (_appIcon != null) return _appIcon;
        var uri = new Uri("pack://application:,,,/Resources/icon.ico");
        using var stream = Application.GetResourceStream(uri)?.Stream;
        _appIcon = stream != null ? new Icon(stream, 16, 16) : SystemIcons.Application;
        return _appIcon;
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _trayTimer?.Stop();
        _trayIcon?.Dispose();
        Task.Run(async () => await RcloneService.Instance.Cleanup()).Wait(TimeSpan.FromSeconds(5));
        _mutex?.ReleaseMutex();
        base.OnExit(e);
    }
}
