using System;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using SkyHook.Services;

namespace SkyHook.Views;

public partial class SetupView : Window
{
    private readonly SetupSession _session;

    public SetupView(SetupSession session)
    {
        InitializeComponent();
        _session = session;
        _session.OnPromptChanged += Session_OnPromptChanged;
        _session.OnPhaseChanged += Session_OnPhaseChanged;
        _session.OnStatusChanged += Session_OnStatusChanged;
    }

    private void Session_OnStatusChanged(string status)
    {
        Dispatcher.Invoke(() => StatusText.Text = status);
    }

    private void Session_OnPhaseChanged(SessionPhase phase)
    {
        Dispatcher.Invoke(() =>
        {
            if (phase == SessionPhase.Done)
            {
                CancelButton.Visibility = Visibility.Collapsed;
                DoneButton.Visibility = Visibility.Visible;
                PromptPanel.Children.Clear();

                if (_session.Succeeded)
                {
                    TitleText.Text = "Remote configured successfully";
                    StatusText.Text = "";
                    var checkmark = new TextBlock
                    {
                        Text = "\uE73E",
                        FontFamily = new FontFamily("Segoe Fluent Icons"),
                        FontSize = 48,
                        Foreground = (Brush)FindResource("SuccessBrush"),
                        HorizontalAlignment = HorizontalAlignment.Center,
                        Margin = new Thickness(0, 32, 0, 0)
                    };
                    PromptPanel.Children.Add(checkmark);
                }
                else
                {
                    TitleText.Text = "Setup failed";
                    StatusText.Text = "The remote could not be configured.";
                }
            }
        });
    }

    private void Session_OnPromptChanged(RclonePrompt? prompt)
    {
        Dispatcher.Invoke(() =>
        {
            PromptPanel.Children.Clear();
            if (prompt == null) return;

            if (!string.IsNullOrEmpty(prompt.Title))
            {
                TitleText.Text = prompt.Title;
            }

            if (!string.IsNullOrEmpty(prompt.HelpText))
            {
                PromptPanel.Children.Add(new TextBlock
                {
                    Text = prompt.HelpText,
                    FontSize = 12,
                    Foreground = (Brush)FindResource("FgSecondaryBrush"),
                    TextWrapping = TextWrapping.Wrap,
                    Margin = new Thickness(0, 0, 0, 12)
                });
            }

            switch (prompt.ControlType)
            {
                case PromptControlType.YesNo:
                    BuildYesNo(prompt);
                    break;
                case PromptControlType.Choices:
                    BuildChoices(prompt);
                    break;
                case PromptControlType.TextField:
                    BuildTextField(prompt);
                    break;
                case PromptControlType.OAuthWait:
                    BuildOAuthWait(prompt);
                    break;
            }
        });
    }

    private void BuildYesNo(RclonePrompt prompt)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };

        var yesBtn = new Button
        {
            Content = prompt.DefaultYes ? "Yes (default)" : "Yes",
            Style = prompt.DefaultYes ? (Style)FindResource("AccentButton") : (Style)FindResource("FluentButton"),
            Padding = new Thickness(24, 8, 24, 8),
            FontSize = 14
        };
        yesBtn.Click += (_, _) => _session.Send("y");
        panel.Children.Add(yesBtn);

        var noBtn = new Button
        {
            Content = !prompt.DefaultYes ? "No (default)" : "No",
            Style = !prompt.DefaultYes ? (Style)FindResource("AccentButton") : (Style)FindResource("FluentButton"),
            Padding = new Thickness(24, 8, 24, 8),
            FontSize = 14,
            Margin = new Thickness(8, 0, 0, 0)
        };
        noBtn.Click += (_, _) => _session.Send("n");
        panel.Children.Add(noBtn);

        PromptPanel.Children.Add(panel);
    }

    private void BuildChoices(RclonePrompt prompt)
    {
        var scroll = new ScrollViewer { MaxHeight = 200, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var stack = new StackPanel();

        foreach (var choice in prompt.Choices)
        {
            var isDefault = choice.Id == prompt.DefaultChoiceId;
            var btn = new Button
            {
                Style = (Style)FindResource("FluentButton"),
                Padding = new Thickness(12, 8, 12, 8),
                Margin = new Thickness(0, 2, 0, 2),
                HorizontalContentAlignment = HorizontalAlignment.Left
            };

            var content = new StackPanel { Orientation = Orientation.Horizontal };
            content.Children.Add(new TextBlock
            {
                Text = choice.Label,
                Foreground = (Brush)FindResource("FgBrush"),
                FontSize = 13
            });
            if (isDefault)
            {
                content.Children.Add(new TextBlock
                {
                    Text = " (default)",
                    Foreground = (Brush)FindResource("FgTertiaryBrush"),
                    FontSize = 11,
                    VerticalAlignment = VerticalAlignment.Center
                });
            }
            btn.Content = content;
            btn.Click += (_, _) => _session.Send(choice.Id);
            stack.Children.Add(btn);
        }

        scroll.Content = stack;
        PromptPanel.Children.Add(scroll);

        // Skip/default button
        if (!string.IsNullOrEmpty(prompt.DefaultChoiceId))
        {
            var skipBtn = new Button
            {
                Content = "Use default",
                Style = (Style)FindResource("FluentButton"),
                Padding = new Thickness(12, 4, 12, 4),
                FontSize = 11,
                Margin = new Thickness(0, 8, 0, 0)
            };
            skipBtn.Click += (_, _) => _session.Send(prompt.DefaultChoiceId);
            PromptPanel.Children.Add(skipBtn);
        }
    }

    private void BuildTextField(RclonePrompt prompt)
    {
        var panel = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };

        Control inputBox;
        if (prompt.IsSecret)
        {
            var pb = new PasswordBox
            {
                Width = 300,
                FontSize = 13,
                FontFamily = new FontFamily("Consolas"),
                Background = (Brush)FindResource("CardBrush"),
                Foreground = (Brush)FindResource("FgBrush"),
                BorderBrush = (Brush)FindResource("BorderBrush"),
                Padding = new Thickness(8, 6, 8, 6),
                HorizontalAlignment = HorizontalAlignment.Left
            };
            inputBox = pb;
        }
        else
        {
            var tb = new TextBox
            {
                Text = prompt.DefaultValue,
                Width = 300,
                Style = (Style)FindResource("FluentTextBox"),
                FontSize = 13,
                FontFamily = new FontFamily("Consolas"),
                HorizontalAlignment = HorizontalAlignment.Left
            };
            inputBox = tb;
        }
        panel.Children.Add(inputBox);

        var btnRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
        var okBtn = new Button { Content = "OK", Style = (Style)FindResource("AccentButton"), Padding = new Thickness(16, 6, 16, 6) };
        okBtn.Click += (_, _) =>
        {
            var value = inputBox is PasswordBox pb2 ? pb2.Password : ((TextBox)inputBox).Text;
            _session.Send(value);
        };
        btnRow.Children.Add(okBtn);

        if (!string.IsNullOrEmpty(prompt.DefaultValue))
        {
            var defaultBtn = new Button { Content = $"Use default ({prompt.DefaultValue})", Style = (Style)FindResource("FluentButton"), Margin = new Thickness(8, 0, 0, 0), FontSize = 11 };
            defaultBtn.Click += (_, _) => _session.Send(prompt.DefaultValue);
            btnRow.Children.Add(defaultBtn);
        }
        else
        {
            var skipBtn = new Button { Content = "Skip", Style = (Style)FindResource("FluentButton"), Margin = new Thickness(8, 0, 0, 0), FontSize = 11 };
            skipBtn.Click += (_, _) => _session.Send("");
            btnRow.Children.Add(skipBtn);
        }

        panel.Children.Add(btnRow);
        PromptPanel.Children.Add(panel);
    }

    private void BuildOAuthWait(RclonePrompt prompt)
    {
        var panel = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 24, 0, 0) };

        // Spinner (simple rotating dots via TextBlock)
        panel.Children.Add(new TextBlock
        {
            Text = "Waiting for browser authorization...",
            FontSize = 14,
            Foreground = (Brush)FindResource("FgBrush"),
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 0, 0, 16)
        });

        panel.Children.Add(new ProgressBar
        {
            IsIndeterminate = true,
            Width = 200,
            Height = 4,
            Foreground = (Brush)FindResource("AccentBrush"),
            Background = (Brush)FindResource("CardBrush"),
            Margin = new Thickness(0, 0, 0, 16)
        });

        if (!string.IsNullOrEmpty(prompt.Url))
        {
            var openBtn = new Button { Content = "Open Browser Manually", Style = (Style)FindResource("FluentButton") };
            openBtn.Click += (_, _) => Process.Start(new ProcessStartInfo(prompt.Url) { UseShellExecute = true });
            panel.Children.Add(openBtn);
        }

        panel.Children.Add(new TextBlock
        {
            Text = "Complete the sign-in in your browser.\nThis window will update automatically.",
            FontSize = 11,
            Foreground = (Brush)FindResource("FgTertiaryBrush"),
            TextAlignment = TextAlignment.Center,
            Margin = new Thickness(0, 12, 0, 0)
        });

        PromptPanel.Children.Add(panel);
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        _session.Cancel();
        DialogResult = false;
        Close();
    }

    private void Done_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = _session.Succeeded;
        Close();
    }

    protected override void OnClosed(EventArgs e)
    {
        _session.OnPromptChanged -= Session_OnPromptChanged;
        _session.OnPhaseChanged -= Session_OnPhaseChanged;
        _session.OnStatusChanged -= Session_OnStatusChanged;
        base.OnClosed(e);
    }
}
