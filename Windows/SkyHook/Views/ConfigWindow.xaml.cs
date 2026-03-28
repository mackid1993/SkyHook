using System;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using SkyHook.Helpers;
using SkyHook.Models;
using SkyHook.Services;

namespace SkyHook.Views;

public partial class ConfigWindow : Window
{
    private string _activeTab = "Remotes";

    public ConfigWindow()
    {
        InitializeComponent();
        RefreshRemoteList();
        ShowRemotesTab();
    }

    // MARK: - Tab Switching

    private void RemotesTab_Click(object sender, RoutedEventArgs e) => ShowRemotesTab();
    private void SettingsTab_Click(object sender, RoutedEventArgs e) => ShowSettingsTab();

    private void ShowRemotesTab()
    {
        _activeTab = "Remotes";
        RemotesTabBtn.Background = (Brush)FindResource("AccentDimBrush");
        SettingsTabBtn.Background = (Brush)FindResource("CardBrush");
        RemoteListPanel.Visibility = Visibility.Visible;
        if (RemoteList.SelectedItem != null)
            ShowRemoteDetail((Remote)((ListBoxItem)RemoteList.SelectedItem).Tag);
        else
            ShowEmptyDetail();
    }

    private void ShowSettingsTab()
    {
        _activeTab = "Settings";
        SettingsTabBtn.Background = (Brush)FindResource("AccentDimBrush");
        RemotesTabBtn.Background = (Brush)FindResource("CardBrush");
        RemoteListPanel.Visibility = Visibility.Collapsed;
        BuildSettingsContent();
    }

    // MARK: - Remote List

    private void RefreshRemoteList()
    {
        RemoteList.Items.Clear();
        foreach (var remote in RcloneService.Instance.Remotes)
        {
            var item = new ListBoxItem
            {
                Content = remote.Name,
                Tag = remote,
                Foreground = (Brush)FindResource("FgBrush"),
                FontSize = 13,
                Padding = new Thickness(8, 6, 8, 6)
            };
            RemoteList.Items.Add(item);
        }
    }

    private void RemoteList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_activeTab == "Remotes" && RemoteList.SelectedItem is ListBoxItem item && item.Tag is Remote remote)
            ShowRemoteDetail(remote);
    }

    // MARK: - Remote Detail

    private void ShowEmptyDetail()
    {
        ContentPanel.Children.Clear();
        ContentPanel.Children.Add(new TextBlock
        {
            Text = "Select a remote or add a new one",
            Foreground = (Brush)FindResource("FgTertiaryBrush"),
            FontSize = 14,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 40, 0, 0)
        });
    }

    private void ShowRemoteDetail(Remote remote)
    {
        ContentPanel.Children.Clear();
        var rclone = RcloneService.Instance;
        var status = rclone.GetMountStatus(remote.Name);

        // Header: icon + name + status
        var header = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 16) };
        header.Children.Add(new TextBlock
        {
            Text = RemoteType.Icon(remote.Type),
            FontFamily = new FontFamily("Segoe Fluent Icons"),
            FontSize = 28,
            Foreground = (Brush)FindResource("AccentBrush"),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 12, 0)
        });
        var headerText = new StackPanel();
        headerText.Children.Add(new TextBlock { Text = remote.Name, FontSize = 20, FontWeight = FontWeights.SemiBold, Foreground = (Brush)FindResource("FgBrush") });
        headerText.Children.Add(new TextBlock { Text = $"{remote.DisplayType} — {status.Label()}", FontSize = 12, Foreground = (Brush)FindResource("FgSecondaryBrush") });
        header.Children.Add(headerText);
        ContentPanel.Children.Add(header);

        // Configuration
        AddSection("Configuration", () =>
        {
            var stack = new StackPanel();
            foreach (var kvp in remote.Config)
            {
                if (kvp.Key == "type") continue;
                var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 2, 0, 2) };
                row.Children.Add(new TextBlock { Text = kvp.Key + ":", Width = 140, Foreground = (Brush)FindResource("FgSecondaryBrush"), FontSize = 12 });
                row.Children.Add(new TextBlock { Text = kvp.Value.Contains("token") ? "••••••••" : kvp.Value, Foreground = (Brush)FindResource("FgBrush"), FontSize = 12 });
                stack.Children.Add(row);
            }
            return stack;
        });

        // Drive Letter
        AddSection("Drive Letter", () =>
        {
            var stack = new StackPanel();
            var combo = new ComboBox { Width = 80, Style = (Style)FindResource("FluentComboBox") };
            var currentLetter = AppSettings.Instance.GetDriveLetter(remote.Name);
            combo.Items.Add(new ComboBoxItem { Content = "Auto", Tag = "" });
            var usedDrives = DriveInfo.GetDrives().Select(d => d.Name[0]).ToHashSet();
            foreach (char c in "ZYXWVUTSRQPONMLKJIHGFED")
            {
                var item = new ComboBoxItem { Content = $"{c}:", Tag = $"{c}:" };
                if (usedDrives.Contains(c)) item.IsEnabled = false;
                combo.Items.Add(item);
                if ($"{c}:" == currentLetter) combo.SelectedItem = item;
            }
            if (combo.SelectedItem == null) combo.SelectedIndex = 0;
            combo.SelectionChanged += (_, _) =>
            {
                if (combo.SelectedItem is ComboBoxItem sel)
                    AppSettings.Instance.SetDriveLetter(remote.Name, (string)sel.Tag);
            };
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(new TextBlock { Text = "Mount as:", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0), Foreground = (Brush)FindResource("FgSecondaryBrush"), FontSize = 12 });
            row.Children.Add(combo);
            stack.Children.Add(row);
            stack.Children.Add(new TextBlock { Text = "Choose a drive letter or leave on Auto to assign the next available.", FontSize = 11, Foreground = (Brush)FindResource("FgTertiaryBrush"), Margin = new Thickness(0, 4, 0, 0) });
            return stack;
        });

        // Performance Settings
        AddSection("Performance", () =>
        {
            var settings = RemoteSettings.Load(remote.Name, remote.Type);
            var stack = new StackPanel();
            AddSettingsField(stack, "Cache Mode", settings.VfsCacheMode, v => { settings.VfsCacheMode = v; settings.Save(remote.Name); }, "off, minimal, writes, full");
            AddSettingsField(stack, "Cache Max Age", settings.VfsCacheMaxAge, v => { settings.VfsCacheMaxAge = v; settings.Save(remote.Name); }, "e.g. 1h, 24h");
            AddSettingsField(stack, "Cache Max Size", settings.VfsCacheMaxSize, v => { settings.VfsCacheMaxSize = v; settings.Save(remote.Name); }, "e.g. 1G, 10G");
            AddSettingsField(stack, "Read Chunk Size", settings.VfsReadChunkSize, v => { settings.VfsReadChunkSize = v; settings.Save(remote.Name); }, "e.g. 4M, 32M, 64M");
            AddSettingsField(stack, "Buffer Size", settings.BufferSize, v => { settings.BufferSize = v; settings.Save(remote.Name); }, "e.g. 256k, 512k");
            AddSettingsField(stack, "Transfers", settings.Transfers, v => { settings.Transfers = v; settings.Save(remote.Name); }, "e.g. 4, 8, 16");
            AddSettingsField(stack, "Dir Cache Time", settings.DirCacheTime, v => { settings.DirCacheTime = v; settings.Save(remote.Name); }, "e.g. 1m, 5m");
            AddSettingsField(stack, "Read Ahead", settings.VfsReadAhead, v => { settings.VfsReadAhead = v; settings.Save(remote.Name); }, "e.g. 32M, 128M");
            AddSettingsField(stack, "Extra Flags", settings.ExtraFlags, v => { settings.ExtraFlags = v; settings.Save(remote.Name); }, "--flag value");

            var resetBtn = new Button { Content = "Reset to Defaults", Style = (Style)FindResource("FluentButton"), FontSize = 11, Padding = new Thickness(8, 3, 8, 3), Margin = new Thickness(0, 8, 0, 0) };
            resetBtn.Click += (_, _) =>
            {
                RemoteSettings.Delete(remote.Name);
                ShowRemoteDetail(remote);
            };
            stack.Children.Add(resetBtn);
            stack.Children.Add(new TextBlock { Text = "Changes apply on next mount", FontSize = 10, Foreground = (Brush)FindResource("FgTertiaryBrush"), Margin = new Thickness(0, 4, 0, 0) });
            return stack;
        });

        // Options
        AddSection("Options", () =>
        {
            var stack = new StackPanel();
            var pathRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };
            pathRow.Children.Add(new TextBlock { Text = "Remote Path:", Width = 100, VerticalAlignment = VerticalAlignment.Center, Foreground = (Brush)FindResource("FgSecondaryBrush"), FontSize = 12 });
            var pathBox = new TextBox { Text = remote.RemotePath, Width = 200, Style = (Style)FindResource("FluentTextBox"), FontSize = 12 };
            pathBox.LostFocus += (_, _) => RcloneService.Instance.SetRemotePath(remote, pathBox.Text);
            pathRow.Children.Add(pathBox);
            stack.Children.Add(pathRow);

            var autoMount = new CheckBox
            {
                Content = "Auto-mount at startup",
                IsChecked = remote.AutoMount,
                Foreground = (Brush)FindResource("FgBrush"),
                FontSize = 12
            };
            autoMount.Click += (_, _) => RcloneService.Instance.ToggleAutoMount(remote);
            stack.Children.Add(autoMount);
            return stack;
        });

        // Actions
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 16, 0, 0) };
        var mountBtn = new Button
        {
            Content = status == MountStatus.Mounted ? "Unmount" : "Mount",
            Style = (Style)FindResource("AccentButton"),
            Padding = new Thickness(16, 6, 16, 6)
        };
        mountBtn.Click += async (_, _) =>
        {
            await RcloneService.Instance.ToggleMount(remote);
            ShowRemoteDetail(remote);
        };
        actions.Children.Add(mountBtn);

        if (status == MountStatus.Mounted)
        {
            var revealBtn = new Button { Content = "Open in Explorer", Style = (Style)FindResource("FluentButton"), Margin = new Thickness(8, 0, 0, 0) };
            revealBtn.Click += (_, _) =>
            {
                var path = RcloneService.Instance.ActualMountPath(remote);
                System.Diagnostics.Process.Start("explorer.exe", path);
            };
            actions.Children.Add(revealBtn);
        }

        var reconfigBtn = new Button { Content = "Reconfigure", Style = (Style)FindResource("FluentButton"), Margin = new Thickness(8, 0, 0, 0) };
        reconfigBtn.Click += (_, _) =>
        {
            var session = new SetupSession();
            var setupWindow = new SetupView(session);
            session.Start(RcloneService.Instance.EffectiveRclonePath, remote.Name, remote.Type, isEdit: true);
            setupWindow.ShowDialog();
            RcloneService.Instance.LoadRemotes();
            RefreshRemoteList();
        };
        actions.Children.Add(reconfigBtn);
        ContentPanel.Children.Add(actions);
    }

    // MARK: - Settings Tab

    private void BuildSettingsContent()
    {
        ContentPanel.Children.Clear();
        var rclone = RcloneService.Instance;

        // How It Works
        AddSection("How SkyHook Works", () =>
        {
            var stack = new StackPanel();
            stack.Children.Add(MakeCaption("SkyHook mounts your cloud storage as Windows drive letters using rclone and WinFSP."));
            stack.Children.Add(MakeCaption("Drive Letters: Each remote mounts as a drive letter (e.g. Z:). You can choose the letter per remote in Advanced Settings."));
            stack.Children.Add(MakeCaption("No admin password required. Mount points are automatically cleaned up when you unmount or delete a remote."));
            return stack;
        });

        // rclone
        AddSection("rclone", () =>
        {
            var stack = new StackPanel();
            var versionText = rclone.IsRcloneInstalled ? $"Version: {rclone.RcloneVersion}" : "Not installed";
            stack.Children.Add(new TextBlock { Text = versionText, FontSize = 13, Foreground = (Brush)FindResource("FgBrush"), Margin = new Thickness(0, 0, 0, 8) });
            var btns = new StackPanel { Orientation = Orientation.Horizontal };
            var installBtn = new Button { Content = rclone.IsRcloneInstalled ? "Update rclone" : "Download & Install rclone", Style = (Style)FindResource("AccentButton") };
            installBtn.Click += async (_, _) => { await rclone.DownloadAndInstallRclone(); BuildSettingsContent(); };
            btns.Children.Add(installBtn);
            if (rclone.IsRcloneInstalled)
            {
                var uninstallBtn = new Button { Content = "Uninstall", Style = (Style)FindResource("DangerButton"), Margin = new Thickness(8, 0, 0, 0) };
                uninstallBtn.Click += (_, _) => { rclone.UninstallRclone(); BuildSettingsContent(); };
                btns.Children.Add(uninstallBtn);
            }
            stack.Children.Add(btns);
            return stack;
        });

        // WinFSP
        AddSection("WinFSP", () =>
        {
            var stack = new StackPanel();
            var installed = WinFspService.Instance.IsInstalled;
            stack.Children.Add(new TextBlock { Text = installed ? "Installed" : "Not installed — required for mounting", FontSize = 13, Foreground = installed ? (Brush)FindResource("SuccessBrush") : (Brush)FindResource("ErrorBrush"), Margin = new Thickness(0, 0, 0, 8) });
            if (!installed)
            {
                var dlBtn = new Button { Content = "Download WinFSP", Style = (Style)FindResource("AccentButton") };
                dlBtn.Click += (_, _) => WinFspService.Instance.OpenDownloadPage();
                stack.Children.Add(dlBtn);
            }
            return stack;
        });

        // Startup
        AddSection("Startup", () =>
        {
            var stack = new StackPanel();
            var loginCb = new CheckBox { Content = "Launch SkyHook at login", IsChecked = AppSettings.Instance.LaunchAtLogin, Foreground = (Brush)FindResource("FgBrush"), FontSize = 12 };
            loginCb.Click += (_, _) => { AppSettings.Instance.LaunchAtLogin = loginCb.IsChecked == true; AppSettings.Instance.Save(); };
            stack.Children.Add(loginCb);
            var autoMountCb = new CheckBox { Content = "Auto-mount remotes at startup", IsChecked = AppSettings.Instance.AutoMountOnLaunch, Foreground = (Brush)FindResource("FgBrush"), FontSize = 12, Margin = new Thickness(0, 6, 0, 0) };
            autoMountCb.Click += (_, _) => { AppSettings.Instance.AutoMountOnLaunch = autoMountCb.IsChecked == true; AppSettings.Instance.Save(); };
            stack.Children.Add(autoMountCb);
            return stack;
        });
    }

    // MARK: - Helpers

    private void AddSection(string title, Func<UIElement> contentBuilder)
    {
        var group = new GroupBox { Style = (Style)FindResource("CardGroupBox") };
        group.Header = new TextBlock { Text = title, FontSize = 14, FontWeight = FontWeights.SemiBold, Foreground = (Brush)FindResource("FgBrush") };
        group.Content = contentBuilder();
        ContentPanel.Children.Add(group);
    }

    private void AddSettingsField(StackPanel parent, string label, string value, Action<string> onChange, string placeholder)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 3, 0, 3) };
        row.Children.Add(new TextBlock { Text = label + ":", Width = 120, TextAlignment = TextAlignment.Right, Foreground = (Brush)FindResource("FgSecondaryBrush"), FontSize = 11, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) });
        var box = new TextBox { Text = value, Width = 140, Style = (Style)FindResource("FluentTextBox"), FontSize = 11, FontFamily = new FontFamily("Consolas") };
        box.LostFocus += (_, _) => onChange(box.Text);
        row.Children.Add(box);
        row.Children.Add(new TextBlock { Text = placeholder, FontSize = 10, Foreground = (Brush)FindResource("FgTertiaryBrush"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) });
        parent.Children.Add(row);
    }

    private TextBlock MakeCaption(string text) => new()
    {
        Text = text,
        FontSize = 12,
        Foreground = (Brush)FindResource("FgSecondaryBrush"),
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(0, 0, 0, 6)
    };

    // MARK: - Actions

    private void AddRemote_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new AddRemoteDialog { Owner = this };
        if (dialog.ShowDialog() == true)
        {
            RcloneService.Instance.LoadRemotes();
            RefreshRemoteList();
        }
    }

    private void DeleteRemote_Click(object sender, RoutedEventArgs e)
    {
        if (RemoteList.SelectedItem is ListBoxItem item && item.Tag is Remote remote)
        {
            var result = MessageBox.Show($"Delete remote \"{remote.Name}\"?", "SkyHook", MessageBoxButton.YesNo);
            if (result == MessageBoxResult.Yes)
            {
                RcloneService.Instance.DeleteRemote(remote);
                RefreshRemoteList();
                ShowEmptyDetail();
            }
        }
    }
}
