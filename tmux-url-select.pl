#!/usr/bin/env perl
#
# tmux-url-select
# mit licensed
#
# URL: https://github.com/mwolson/tmux-url-select/
# Adapted from https://github.com/dequis/tmux-url-select/

use strict;
use warnings;

### config

our $tmux_command = $ENV{TMUX_URL_SELECT_TMUX_CMD} || 'tmux';
our $launch_url_command;
our $yank_url_command;

use constant SHOW_STATUS_BAR => 1;
use constant VERBOSE_MESSAGES => 0;
use constant TMUX_WINDOW_TITLE => 'Select URL';
use constant TMUX_WINDOW_ID => 9999;
use constant HIDE_WINDOW => 1;

use constant PROMPT_COLOR => "\033[42;30m";
use constant ACTIVE_LINK_HIGHLIGHT => "\033[44;4m";
use constant NORMAL_LINK_HIGHLIGHT => "\033[94;1;4m";

# other options:
# - blue background, underlined: \033[44;4m
# - 256 color term light blue: \033[38;5;39m
# - bold bright blue: \033[94;1;4m
# - bright blue background: \033[104;4m
# - just underlined: \033[4m

# regex stolen from urxvtperls url-select.pl
my $url_pattern = qr{(
    (?:https?://|ftp://|news://|git://|mailto:|file://|www\.)
    [\w\-\@;\/?:&=%\$_.+!*\x27(),~#\x1b\[\]]+[\w\-\@;\/?&=%\$_+!*\x27(~]
)}x;

### config end

my $raw_buffer;
my $buffer;
my $buffer_first_newline_position;
my @matches;
my $match_count;
my $selection = 0;

# terminal helper functions

sub clear {
    print "\033[H\033[2J";
}

sub display_status_bar {
    my $is_first_line = shift;
    my $position = $is_first_line ? "2;2" : "1;2";
    print sprintf("\033[%sH%s URL select: (%s/%s) [j/k/y/o/q/enter] \033[0m", $position, PROMPT_COLOR, $selection+1, $match_count);
}

sub display_highlighted_buffer {
    my $i = 0;
    my $is_first_line = 0;
    my $cb = sub {
        if ($i++ == $selection) {
            $is_first_line = 1 if ($+[0] < $buffer_first_newline_position);
            return ACTIVE_LINK_HIGHLIGHT."$1\033[0m";
            return;
        }
        return NORMAL_LINK_HIGHLIGHT."$1\033[0m" if NORMAL_LINK_HIGHLIGHT;
        return $1;
    };
    print $buffer =~ s/($url_pattern)/&$cb()/ger;
    return $is_first_line;
}

sub display_stuff {
    clear();
    my $is_first_line = display_highlighted_buffer();
    display_status_bar($is_first_line) if SHOW_STATUS_BAR;
}

# tmux command helpers

sub tmux_display_message {
    system $tmux_command, 'display-message', shift;
}

sub tmux_switch_to_last {
    system $tmux_command, 'last-window';
}

sub tmux_select_my_window {
    system $tmux_command, "select-window", "-t", TMUX_WINDOW_ID;
}

sub tmux_capture_pane {
    system $tmux_command, "capture-pane", "-eJ";
}

sub tmux_get_buffer {
    return `$tmux_command show-buffer`;
}

sub tmux_open_inner_window {
    system $tmux_command, "new-window", "-dn", "", "-t", TMUX_WINDOW_ID, "$0 inner";
    system $tmux_command, "setw", "-qt", TMUX_WINDOW_ID, "window-status-format", "";
    system $tmux_command, "setw", "-qt", TMUX_WINDOW_ID, "window-status-current-format", "";
}

# other shell helpers

sub enable_canonical_mode {
    # "canonical mode" to read char by char, thanks roger.
    system "stty", "-icanon", "cbreak", "min", "1", "-echo";
}

sub single_quote_escape {
    return "'".(shift =~ s/\'/%27/gr)."'";
}

sub which {
    my $binary = shift;
    return `which $binary 2>/dev/null`;
}

sub locate_launch_url_command {
    if ($launch_url_command) {
        return $launch_url_command;
    }

    foreach ($ENV{TMUX_URL_SELECT_OPEN_CMD}, 'xdg-open', 'open') {
        if ($_ && which($_)) {
            $launch_url_command = $_;
            last;
        }
    }

    if ($launch_url_command) {
        return $launch_url_command;
    } else {
        tmux_display_message("No xdg-open or open command found");
        system $tmux_command, "delete-buffer";
        exit 0;
    }
}

sub locate_yank_url_command {
    if ($yank_url_command) {
        return $yank_url_command;
    }

    my $select_yank_url_command = sub {
        if ($ENV{TMUX_URL_SELECT_CLIP_CMD}) {
            return $ENV{TMUX_URL_SELECT_CLIP_CMD};
        } elsif (which('wl-copy')) {
            return 'wl-copy';
        } elsif (which('xsel')) {
            return 'xsel -i';
        } elsif (which('xclip')) {
            return 'xclip -i';
        } elsif (which('pbcopy')) {
            return 'pbcopy';
        } elsif (which('clip.exe')) {
            return 'clip.exe';
        } else {
            return '';
        }
    };

    $yank_url_command = $select_yank_url_command->();

    if ($yank_url_command) {
        return $yank_url_command;
    } else {
        tmux_display_message("No wl-copy, xsel, xclip, pbcopy, or clip.exe command found");
        system $tmux_command, "delete-buffer";
        exit 0;
    }
}

# actions

sub fix_url {
    my $url = shift;
    # some silly url openers think ^www. urls are files
    $url = "http://".$url if $url =~ /^www\./;
    # clear out color codes
    $url =~ s/\x1b\[[0-9;]*m//g;
    return $url;
}

sub safe_exec {
    my ($command, $message) = @_;
    $SIG{CHLD} = 'IGNORE';
    $SIG{HUP} = 'IGNORE';

    unless (fork) {
        tmux_display_message($message) if VERBOSE_MESSAGES;
        exec $command;
    }
}

sub launch_url {
    my $url = fix_url(shift);
    tmux_switch_to_last() if shift;

    my $command = sprintf(
        "%s %s",
        locate_launch_url_command(),
        single_quote_escape($url)
    );
    safe_exec($command, "Launched ". $url);
}

sub yank_url {
    my $url = fix_url(shift);
    tmux_switch_to_last() if shift;
    my $command = sprintf(
        "echo %s | %s",
        single_quote_escape($url),
        locate_yank_url_command()
    );
    safe_exec($command, "Yanked ". $url);
}

# main functions

sub main_inner {
    $raw_buffer = tmux_get_buffer();
    system $tmux_command, "delete-buffer";

    $buffer = $raw_buffer =~ s/\n$//r;
    $buffer_first_newline_position = index($raw_buffer, "\n");

    @matches = ($buffer =~ /$url_pattern/g);
    $match_count = @matches;
    exit 1 if !$match_count;

    $selection = $#matches;

    display_stuff();

    enable_canonical_mode();

    # switch to the tmux-url-select window now to avoid 'flickering'
    tmux_select_my_window();

    # main loop
    while(defined($_ = getc)) {
        $selection++ if /[jB]/;
        $selection-- if /[kA]/;
        $selection = ($_-1) if /[0-9]/;
        $selection %= $match_count;
        my $do_return = /[qyo\n]/;
        yank_url($matches[$selection], $do_return) if /[yY]/;
        launch_url($matches[$selection], $do_return) if /[\noO]/;
        return if $do_return;
        display_stuff();
    }
}

sub main {
    tmux_capture_pane();

    @matches = tmux_get_buffer() =~ /$url_pattern/g;
    $match_count = @matches;

    if (!$match_count) {
        tmux_display_message("No URLs");
        system $tmux_command, "delete-buffer";
        exit 0;
    }

    # open window here, backgrounded
    tmux_open_inner_window();
}

if (!@ARGV) {
    main();
} elsif ($ARGV[0] eq "inner") {
    main_inner();
}
