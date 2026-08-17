#!/usr/bin/env perl
use strict;
use warnings;

use Cwd qw(abs_path getcwd);
use File::Basename qw(basename dirname);
use File::Find qw(find);
use File::Path qw(make_path remove_tree);
use Getopt::Long qw(GetOptions);
use JSON::PP qw(decode_json);

my %GENERATED_CONTENT = (
    personality_custom => <<'EOF',
# Personality

Selected personality: {{ personality }}

Replace this file with the exact personality instructions you want injected for
the chosen personality. The runtime substitutes `{{ personality }}` with one of:

- `none`
- `friendly`
- `pragmatic`
EOF
    instructions => <<'EOF',
# System Instructions

Use this file as a companion template for the top-level `instructions` string
field in `config.toml`.

Replace this file with the exact system-level instructions you want to copy into
that inline TOML string.
EOF
    developer_instructions => <<'EOF',
# Developer Instructions

Use this file as a companion template for the top-level
`developer_instructions` string field in `config.toml`.

Replace this file with the exact developer-role instructions you want to copy
into that inline TOML string.
EOF
    realtime_ws_startup_context => <<'EOF',
# Realtime Startup Context

Use this file as a companion template for the
`experimental_realtime_ws_startup_context` string field in `config.toml`.

Replace this file with the exact websocket startup context you want to append.
An empty string disables the synthesized startup context entirely.
EOF
);

my $repo_root;
my $output_root;
my $help = 0;

GetOptions(
    "repo-root=s"   => \$repo_root,
    "output-root=s" => \$output_root,
    "help|h"        => \$help,
) or die "invalid arguments\n";

if ($help) {
    print <<"EOF";
Usage: scripts/release/instruct.pl [options]

  --repo-root PATH   Repository root to read from. Defaults to the repo that
                     contains this script.
  --output-root PATH Destination .mcr root. Defaults to <repo-root>/.mcr
  -h, --help         Show this help text.
EOF
    exit 0;
}

my $script_path = abs_path($0);
my $default_repo_root = abs_path(dirname($script_path) . "/../..");
$repo_root = defined $repo_root ? make_absolute($repo_root) : $default_repo_root;
die "repo root not found\n" if !defined $repo_root || !-d $repo_root;
$output_root = defined $output_root ? make_absolute($output_root) : "$repo_root/.mcr";

my $inventory = load_inventory_from_helper($repo_root);
my @override_assets = @{ $inventory->{override_assets} || [] };
my @static_generated_assets = @{ $inventory->{static_generated_assets} || [] };

my %override_source_paths;
for my $asset (@override_assets) {
    next if ($asset->{kind} || "") ne "file";
    $override_source_paths{ $asset->{source} } = 1;
}

my @static_file_assets = discover_static_file_assets($repo_root, \%override_source_paths);

my $override_root = "$output_root/override-instructions";
my $static_root = "$output_root/static-instructions";

remove_tree($override_root);
remove_tree($static_root);
make_path($override_root);
make_path($static_root);

for my $asset (@override_assets) {
    materialize_asset($repo_root, $override_root, $asset);
}

for my $asset (@static_file_assets, @static_generated_assets) {
    materialize_asset($repo_root, $static_root, $asset);
}

printf(
    "Generated instruction artifacts under %s (%d override, %d static)\n",
    $output_root,
    scalar(@override_assets),
    scalar(@static_file_assets) + scalar(@static_generated_assets),
);
exit 0;

sub load_inventory_from_helper {
    my ($root) = @_;
    my $helper = "$root/scripts/release/release_contract.py";
    open my $fh, "-|", "python3", $helper, "print-inventory", "--repo-root", $root
        or die "failed to run $helper: $!\n";
    local $/;
    my $text = <$fh>;
    close $fh or die "failed to load inventory via $helper\n";
    my $data = decode_json($text);
    die "inventory helper must return a JSON object\n" if ref($data) ne "HASH";
    return $data;
}

sub discover_static_file_assets {
    my ($root, $override_sources) = @_;
    my @assets;
    my %seen_targets;

    find(
        {
            no_chdir => 1,
            wanted => sub {
                return if !-f $_;
                return if $_ !~ /\.rs\z/;
                return if is_test_rust_file($File::Find::name);

                my $rs_path = $File::Find::name;
                my $text = read_utf8($rs_path);
                while ($text =~ /include_str!\(\s*"([^"]+\.(?:md|xml))"\s*\)/g) {
                    my $resolved = abs_path(dirname($rs_path) . "/$1");
                    die "missing include_str target for $rs_path: $1\n"
                        if !defined $resolved || !-f $resolved;
                    my $source = repo_relative_path($root, $resolved);
                    next if $source =~ m{\Acodex-rs/(?:ext/)?memories/};
                    next if $override_sources->{$source};
                    my $target = static_output_path_from_source($source);
                    die "duplicate static target path: $target\n" if $seen_targets{$target};
                    $seen_targets{$target} = 1;
                    push @assets, {
                        kind => "file",
                        source => $source,
                        target => $target,
                        replacements => [],
                    };
                }
            },
        },
        "$root/codex-rs",
    );

    return sort { $a->{target} cmp $b->{target} } @assets;
}

sub is_test_rust_file {
    my ($path) = @_;
    return 1 if $path =~ m{/(?:tests|fixtures)/};
    my $name = basename($path);
    return 1 if $name eq "tests.rs";
    return 1 if $name =~ /_tests\.rs\z/;
    return 0;
}

sub repo_relative_path {
    my ($root, $path) = @_;
    my $prefix = "$root/";
    die "path is outside repo root: $path\n" if index($path, $prefix) != 0;
    return substr($path, length($prefix));
}

sub static_output_path_from_source {
    my ($source) = @_;

    return "modes/$1"
        if $source =~ m{\Acodex-rs/collaboration-mode-templates/templates/(.+)\z};
    return "compact/$1"
        if $source =~ m{\Acodex-rs/prompts/templates/compact/(.+)\z};
    return "prompts/goals/$1"
        if $source =~ m{\Acodex-rs/prompts/templates/goals/(.+)\z};
    return "prompts/realtime/$1"
        if $source =~ m{\Acodex-rs/prompts/templates/realtime/(.+)\z};
    return "ext-goal/$1"
        if $source =~ m{\Acodex-rs/ext/goal/templates/(.+)\z};
    return "image-generation/$1"
        if $source =~ m{\Acodex-rs/ext/image-generation/(.+)\z};
    return "web-search/$1"
        if $source =~ m{\Acodex-rs/ext/web-search/(.+)\z};
    return "guardian/$1"
        if $source =~ m{\Acodex-rs/core/src/guardian/(.+)\z};
    return "models-manager/$1"
        if $source =~ m{\Acodex-rs/models-manager/(.+)\z};
    return "protocol/$1"
        if $source =~ m{\Acodex-rs/protocol/src/prompts/(.+)\z};

    $source =~ s{\Acodex-rs/}{};
    return $source;
}

sub materialize_asset {
    my ($root, $destination_root, $asset) = @_;
    my $kind = $asset->{kind} || "";
    my $content;

    if ($kind eq "file") {
        $content = read_utf8("$root/$asset->{source}");
    } elsif ($kind eq "const") {
        $content = extract_const_string("$root/$asset->{source}", $asset->{symbol});
    } elsif ($kind eq "function") {
        $content = extract_function_first_string("$root/$asset->{source}", $asset->{symbol});
    } elsif ($kind eq "generated") {
        $content = generated_content($asset->{generated_key});
    } else {
        die "unsupported asset kind: $kind\n";
    }

    for my $replacement (@{ $asset->{replacements} || [] }) {
        my ($old, $new) = @$replacement;
        $content =~ s/\Q$old\E/$new/g;
    }

    $content = normalize_block($content);
    my $destination = "$destination_root/$asset->{target}";
    make_path(dirname($destination));
    write_utf8($destination, "$content\n");
}

sub generated_content {
    my ($key) = @_;
    die "unknown generated content key: $key\n" if !exists $GENERATED_CONTENT{$key};
    return $GENERATED_CONTENT{$key};
}

sub read_utf8 {
    my ($path) = @_;
    open my $fh, "<:encoding(UTF-8)", $path or die "failed to read $path: $!\n";
    local $/;
    my $content = <$fh>;
    close $fh or die "failed to close $path: $!\n";
    return $content;
}

sub write_utf8 {
    my ($path, $content) = @_;
    open my $fh, ">:encoding(UTF-8)", $path or die "failed to write $path: $!\n";
    print {$fh} $content or die "failed to write $path: $!\n";
    close $fh or die "failed to close $path: $!\n";
}

sub normalize_block {
    my ($text) = @_;
    $text =~ s/\r\n?/\n/g;
    $text =~ s/^\s+//s;
    $text =~ s/\s+$//s;
    return $text;
}

sub extract_const_string {
    my ($path, $const_name) = @_;
    my $text = read_utf8($path);

    while ($text =~ /(?:pub(?:\([^)]*\))?\s+)?const\s+([A-Z0-9_]+)\s*:\s*&str\s*=\s*/mg) {
        next if $1 ne $const_name;
        my $expression_start = pos($text);
        my $expression_end = find_expression_end($text, $expression_start, ";");
        die "missing expression terminator for $const_name in $path\n"
            if !defined $expression_end;
        my $expression = substr($text, $expression_start, $expression_end - $expression_start);
        my $value = evaluate_expression($expression, $path);
        die "unsupported expression for $const_name in $path\n" if !defined $value;
        return $value;
    }

    die "missing constant $const_name in $path\n";
}

sub extract_function_first_string {
    my ($path, $function_name) = @_;
    my $text = read_utf8($path);
    my ($start, $end) = function_range($text, $function_name);
    my $body = substr($text, $start, $end - $start);

    if ($body =~ /format!\s*\(/g) {
        my $literal = find_string_literal($body, pos($body));
        return decode_string_literal($literal) if defined $literal;
    }

    my $literal = find_string_literal($body, 0);
    return decode_string_literal($literal) if defined $literal;

    die "missing string literal in $path:$function_name\n";
}

sub function_range {
    my ($text, $function_name) = @_;
    my @patterns = (
        qr/^fn\s+\Q$function_name\E\s*\(/m,
        qr/^async\s+fn\s+\Q$function_name\E\s*\(/m,
        qr/^pub(?:\([^)]*\))?\s+(?:async\s+)?fn\s+\Q$function_name\E\s*\(/m,
    );

    my $start = -1;
    for my $pattern (@patterns) {
        if ($text =~ /$pattern/g) {
            $start = $-[0];
            last;
        }
    }
    die "missing function $function_name\n" if $start < 0;

    my $rest = substr($text, $start + 1);
    my $end = length($text);
    while ($rest =~ /^(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn\s+[A-Za-z_][A-Za-z0-9_]*\s*\(/mg) {
        $end = $start + 1 + $-[0];
        last;
    }

    return ($start, $end);
}

sub evaluate_expression {
    my ($expression, $source_path) = @_;
    my $stripped = $expression;
    $stripped =~ s/^\s+//s;
    $stripped =~ s/\s+$//s;
    return undef if $stripped eq "";

    if ($stripped =~ s/\.to_string\(\)\z//) {
        return evaluate_expression($stripped, $source_path);
    }
    if ($stripped =~ s/\.trim_end\(\)\z//) {
        my $value = evaluate_expression($stripped, $source_path);
        return undef if !defined $value;
        $value =~ s/\s+\z//s;
        return $value;
    }
    if ($stripped =~ s/\.trim\(\)\z//) {
        my $value = evaluate_expression($stripped, $source_path);
        return undef if !defined $value;
        $value =~ s/^\s+//s;
        $value =~ s/\s+\z//s;
        return $value;
    }
    if ($stripped =~ /^include_str!\(\s*"([^"]+)"\s*\)$/s) {
        my $include_path = abs_path(dirname($source_path) . "/$1");
        die "include target not found for $source_path: $1\n" if !defined $include_path;
        return read_utf8($include_path);
    }
    if ($stripped =~ /^concat!\((.*)\)\z/s) {
        return evaluate_concat_arguments($1, $source_path);
    }

    my $literal = find_string_literal($stripped, 0, 1);
    return decode_string_literal($literal) if defined $literal;
    return undef;
}

sub evaluate_concat_arguments {
    my ($args, $source_path) = @_;
    my @parts;
    my $start = 0;
    my $depth = 0;
    my $length = length($args);

    for (my $i = 0; $i < $length; $i += 1) {
        my $next_index = skip_string_literal($args, $i);
        if (defined $next_index) {
            $i = $next_index - 1;
            next;
        }

        my $char = substr($args, $i, 1);
        if ($char =~ /[\(\[\{]/) {
            $depth += 1;
        } elsif ($char =~ /[\)\]\}]/) {
            $depth -= 1;
        } elsif ($char eq "," && $depth == 0) {
            push @parts, substr($args, $start, $i - $start);
            $start = $i + 1;
        }
    }
    push @parts, substr($args, $start);

    my $combined = "";
    for my $part (@parts) {
        next if $part !~ /\S/;
        my $value = evaluate_expression($part, $source_path);
        return undef if !defined $value;
        $combined .= $value;
    }
    return $combined;
}

sub find_expression_end {
    my ($text, $start, $terminator) = @_;
    my $depth = 0;
    my $i = $start;
    my $length = length($text);

    while ($i < $length) {
        my $next_index = skip_string_literal($text, $i);
        if (defined $next_index) {
            $i = $next_index;
            next;
        }

        my $char = substr($text, $i, 1);
        if ($char =~ /[\(\[\{]/) {
            $depth += 1;
        } elsif ($char =~ /[\)\]\}]/) {
            $depth -= 1;
        } elsif ($char eq $terminator && $depth == 0) {
            return $i;
        }
        $i += 1;
    }

    return undef;
}

sub skip_string_literal {
    my ($text, $start) = @_;
    my $length = length($text);
    return undef if $start >= $length;
    my $char = substr($text, $start, 1);

    if ($char eq '"') {
        my $i = $start + 1;
        while ($i < $length) {
            my $current = substr($text, $i, 1);
            if ($current eq "\\") {
                $i += 2;
                next;
            }
            if ($current eq '"') {
                return $i + 1;
            }
            $i += 1;
        }
        die "unterminated string literal\n";
    }

    return undef if $char ne "r";
    my $remaining = substr($text, $start);
    return undef if $remaining !~ /^r(#+)?"/;
    my $hashes = defined $1 ? $1 : "";
    my $content_start = $start + 2 + length($hashes);
    my $terminator = '"' . $hashes;
    my $end = index($text, $terminator, $content_start);
    die "unterminated raw string literal\n" if $end < 0;
    return $end + length($terminator);
}

sub find_string_literal {
    my ($text, $start, $require_full) = @_;
    $require_full ||= 0;
    my $length = length($text);
    my $i = $start;

    while ($i < $length) {
        my $char = substr($text, $i, 1);
        if ($char eq '"') {
            my $end = skip_string_literal($text, $i);
            my $literal = substr($text, $i, $end - $i);
            if ($require_full) {
                my $leading = substr($text, 0, $i);
                my $trailing = substr($text, $end);
                return undef if $leading =~ /\S/ || $trailing =~ /\S/;
            }
            return $literal;
        }
        if ($char eq "r") {
            my $end = skip_string_literal($text, $i);
            if (defined $end) {
                my $literal = substr($text, $i, $end - $i);
                if ($require_full) {
                    my $leading = substr($text, 0, $i);
                    my $trailing = substr($text, $end);
                    return undef if $leading =~ /\S/ || $trailing =~ /\S/;
                }
                return $literal;
            }
        }
        $i += 1;
    }

    return undef;
}

sub decode_string_literal {
    my ($literal) = @_;
    if ($literal =~ /^r(#+)?"/s) {
        my $hashes = defined $1 ? $1 : "";
        my $prefix_length = 2 + length($hashes);
        my $suffix_length = 1 + length($hashes);
        return substr(
            $literal,
            $prefix_length,
            length($literal) - $prefix_length - $suffix_length,
        );
    }

    my $content = substr($literal, 1, length($literal) - 2);
    $content =~ s/\\\\/\0ESCAPED_BACKSLASH\0/g;
    $content =~ s/\\"/"/g;
    $content =~ s/\\n/\n/g;
    $content =~ s/\\r/\r/g;
    $content =~ s/\\t/\t/g;
    $content =~ s/\\0/\0/g;
    $content =~ s/\0ESCAPED_BACKSLASH\0/\\/g;
    return $content;
}

sub make_absolute {
    my ($path) = @_;
    return $path if $path =~ m{\A/};
    my $resolved = abs_path($path);
    return $resolved if defined $resolved;
    return abs_path(getcwd()) . "/$path";
}
