using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using SkyHook.Models;
using SkyHook.Services;

namespace SkyHook.Views;

public partial class TrayPopup : Window
{
    private readonly DispatcherTimer _refreshTimer;

    public TrayPopup()
    {
        InitializeComponent();
        _refreshTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _refreshTimer.Tick += (_, _) => RefreshContent();
        _refreshTimer.Start();
        RefreshContent();
    }

    private void RefreshContent()
    {
        var rclone = RcloneService.Instance;
        VersionText.Text = rclone.RcloneVersion ?? "";
        UpdateButton.Visibility = rclone.UpdateAvailable ? Visibility.Visible : Visibility.Collapsed;
        StatusText.Text = rclone.StatusMessage ?? "";

        ContentPanel.Children.Clear();

        if (!rclone.IsRcloneInstalled)
        {
            AddInfoCard("rclone is not installed", "Download & Install rclone to get started.",
                "Download && Install rclone", async (_, _) => await rclone.DownloadAndInstallRclone());
            return;
        }

        if (!WinFspService.Instance.IsInstalled)
        {
            AddInfoCard("WinFSP is required", "WinFSP provides the virtual file system driver needed to mount cloud storage as drive letters.",
                "Download WinFSP", (_, _) => WinFspService.Instance.OpenDownloadPage());
            return;
        }

        if (!rclone.Remotes.Any())
        {
            AddInfoCard("No remotes configured", "Add a cloud storage remote to get started.",
                "Configure Remotes", (_, _) => ((App)Application.Current).OpenConfigWindow());
            return;
        }

        foreach (var remote in rclone.Remotes)
        {
            var status = rclone.GetMountStatus(remote.Name);
            AddRemoteRow(remote, status);
        }

        // Transfer activity
        var monitor = TransferMonitor.Instance;
        if (monitor.Transfers.Any())
        {
            ContentPanel.Children.Add(new Separator { Margin = new Thickness(0, 8, 0, 8) });
            var header = new TextBlock
            {
                Text = $"Transfers ({monitor.Transfers.Count})",
                FontSize = 12,
                FontWeight = FontWeights.SemiBold,
                Foreground = (Brush)FindResource("FgSecondaryBrush"),
                Margin = new Thickness(4, 0, 0, 4)
            };
            ContentPanel.Children.Add(header);

            foreach (var transfer in monitor.Transfers.Take(5))
            {
                var row = new Border
                {
                    Background = (Brush)FindResource("CardBrush"),
                    CornerRadius = new CornerRadius(4),
                    Padding = new Thickness(8, 4, 8, 4),
                    Margin = new Thickness(0, 2, 0, 2)
                };
                var stack = new StackPanel();
                stack.Children.Add(new TextBlock
                {
                    Text = transfer.Name,
                    FontSize = 11,
                    Foreground = (Brush)FindResource("FgBrush"),
                    TextTrimming = TextTrimming.CharacterEllipsis
                });
                stack.Children.Add(new TextBlock
                {
                    Text = $"{transfer.SpeedFormatted} — {transfer.Percentage:F0}%",
                    FontSize = 10,
                    Foreground = (Brush)FindResource("FgTertiaryBrush")
                });
                row.Child = stack;
                ContentPanel.Children.Add(row);
            }
        }
    }

    private void AddRemoteRow(Remote remote, MountStatus status)
    {
        var border = new Border
        {
            Background = (Brush)FindResource("CardBrush"),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(10, 8, 10, 8),
            Margin = new Thickness(0, 2, 0, 2),
            Cursor = System.Windows.Input.Cursors.Hand
        };
        border.MouseEnter += (_, _) => border.Background = (Brush)FindResource("CardHoverBrush");
        border.MouseLeave += (_, _) => border.Background = (Brush)FindResource("CardBrush");

        var panel = new DockPanel();

        // Status dot
        var statusColor = status switch
        {
            MountStatus.Mounted => (Brush)FindResource("SuccessBrush"),
            MountStatus.Mounting or MountStatus.Unmounting => (Brush)FindResource("WarningBrush"),
            _ => (Brush)FindResource("FgTertiaryBrush")
        };
        var dot = new Ellipse { Width = 8, Height = 8, Fill = statusColor, Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        panel.Children.Add(dot);

        // Icon + Name
        var icon = new TextBlock
        {
            Text = RemoteType.Icon(remote.Type),
            FontFamily = new FontFamily("Segoe Fluent Icons"),
            FontSize = 16,
            Foreground = (Brush)FindResource("AccentBrush"),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0)
        };
        panel.Children.Add(icon);

        var nameBlock = new TextBlock
        {
            Text = remote.Name,
            FontSize = 13,
            Foreground = (Brush)FindResource("FgBrush"),
            VerticalAlignment = VerticalAlignment.Center
        };
        panel.Children.Add(nameBlock);

        // Mount/unmount button
        var mountBtn = new Button
        {
            Content = status == MountStatus.Mounted ? "\uF847" : "\uE768", // Eject / Play
            FontFamily = new FontFamily("Segoe Fluent Icons"),
            FontSize = 14,
            Style = (Style)FindResource("FluentButton"),
            Padding = new Thickness(6, 4, 6, 4),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center
        };
        mountBtn.Click += async (_, _) => await RcloneService.Instance.ToggleMount(remote);
        DockPanel.SetDock(mountBtn, Dock.Right);
        panel.Children.Insert(0, mountBtn); // Insert at 0 so DockPanel.Dock=Right works

        border.Child = panel;
        ContentPanel.Children.Add(border);
    }

    private void AddInfoCard(string title, string description, string buttonText, RoutedEventHandler onClick)
    {
        var card = new Border
        {
            Background = (Brush)FindResource("CardBrush"),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(16),
            Margin = new Thickness(0, 8, 0, 8)
        };
        var stack = new StackPanel();
        stack.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 14,
            FontWeight = FontWeights.SemiBold,
            Foreground = (Brush)FindResource("FgBrush"),
            Margin = new Thickness(0, 0, 0, 4)
        });
        stack.Children.Add(new TextBlock
        {
            Text = description,
            FontSize = 12,
            Foreground = (Brush)FindResource("FgSecondaryBrush"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12)
        });
        var btn = new Button { Content = buttonText, Style = (Style)FindResource("AccentButton") };
        btn.Click += onClick;
        stack.Children.Add(btn);
        card.Child = stack;
        ContentPanel.Children.Add(card);
    }

    private void Configure_Click(object sender, RoutedEventArgs e)
    {
        Hide();
        ((App)Application.Current).OpenConfigWindow();
    }

    private void Quit_Click(object sender, RoutedEventArgs e)
    {
        Hide();
        Task.Run(async () => await RcloneService.Instance.Cleanup()).Wait(TimeSpan.FromSeconds(5));
        Application.Current.Shutdown();
    }

    private async void UpdateButton_Click(object sender, RoutedEventArgs e)
    {
        await RcloneService.Instance.DownloadAndInstallRclone();
    }

    protected override void OnClosed(EventArgs e)
    {
        _refreshTimer.Stop();
        base.OnClosed(e);
    }
}
