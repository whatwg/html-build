#!/usr/bin/perl -w
# -d:DProf
use strict;
use File::Path;
use File::Basename;
use Time::HiRes qw(time);

$| = 1;

my $verbose = $ARGV[0] && '--verbose' eq "$ARGV[0]";
sub report($) { print STDERR $_[0] if $verbose; }

report "Loading...";
my @lines = <STDIN>;

report "\rPreprocessing...";

# monitoring
my $lineNumber = 0;
my $lastProgress = -1;
my $maxProgress = 20;
my $start = time;

# actual work
my $currentRepresents = '';
my $represents = {};
my $parserExpanderState = undef;
my $parserExpanderMode = 'passthrough';

while (@lines) {
    my $line = shift @lines;
    $lineNumber += 1;
    my $progress = int($maxProgress * $lineNumber / (scalar @lines + $lineNumber));
    if ($progress != $lastProgress) {
        my $rate = 0;
        my $elapsed = (time - $start);
        if ($elapsed > 0) {
            $rate = $lineNumber / $elapsed;
        }
        report sprintf "\rParsing... [" . ('#' x $progress) . (' ' x ($maxProgress - $progress)) . "] %5d lines per second", $rate;
        $lastProgress = $progress;
    }

    if ($line =~ m|^(.*)<!--BOILERPLATE ([-.a-z0-9]+)-->(.*)\n$|os) {
        unshift @lines, split("\n", $1 . `cat $ENV{'HTML_CACHE'}/$2` . $3);
        next;
    } elsif ($line =~ m!^( *)<pre[^>]*>(?:<code[^>]*>)?EXAMPLE (offline/|workers/|canvas/)((?:[-a-z0-9]+/){1,2}[-a-z0-9]+.[-a-z0-9]+)(?:</code>)?</pre> *\n$!os) {
        my $indent = $1;
        my $folder = $2;
        my $example = $3;

        my $data;
        my $fh;

        open($fh, "<:encoding(UTF-8)", "$ENV{'HTML_SOURCE'}/demos/$folder$example")
          or die "\rCannot open $ENV{'HTML_SOURCE'}/demos/$folder$example";
        while (<$fh>) {
          $data .= $_;
        }
        close $fh;

        $data =~ s/&/&amp;/gos;
        $data =~ s/</&lt;/gos;
        unshift @lines, split("\n", "$indent<pre>$data</pre>");
        next;
    } elsif ($line =~ m|^ *<p>The <code>([^<]+)</code> element <span>represents</span> (.*)</p> *\n$|os) {
        $represents->{$1} = "\u$2";
    } elsif ($line =~ m|^ *<p>The <code>([^<]+)</code> element <span>represents</span> ?(.*)\n$|os) {
        $currentRepresents = $1;
        $represents->{$currentRepresents} = "\u$2";
    } elsif ($currentRepresents) {
        if ($line =~ m|^ *(.*)</p> *\n$|os) {
            $represents->{$currentRepresents} .= " $1";
            $currentRepresents = '';
        } elsif ($line =~ m|^ *(.+?) *\n$|os) {
            $represents->{$currentRepresents} .= " $1";
        } else {
            die "missed end of <$currentRepresents> intro.\n";
        }
    }
    $line =~ s|<!--REPRESENTS ([^>]+)-->| if (exists $represents->{$1}) { $represents->{$1} } else { die "\nUnknown element <$1> used in REPRESENTS pragma.\n" }|gose;

    $line = parserExpander($line);

    print "$line";
}
report "\n";

sub expand {
    my($val) = @_;
    return 'a <span>space character</span>' if $val eq 'space character';
    return 'a U+002D HYPHEN-MINUS character (-)' if $val eq '-';
    return 'a U+002E FULL STOP character (.)' if $val eq '.';
    return 'an <span data-x="ASCII digits">ASCII digit</span>' if $val eq '0-9';
    return 'a U+0045 LATIN CAPITAL LETTER E character or a U+0065 LATIN SMALL LETTER E character' if $val eq 'e/E';
    return 'an <span data-x="uppercase ASCII letters">uppercase ASCII letter</span> or a <span data-x="lowercase ASCII letters">lowercase ASCII letter</span>' if $val eq 'letter';
    return 'EOF' if $val eq 'eof';
    die "unknown value type: '$val'";
}

sub parserExpander {
    $_ = shift;
    chomp;
    my $output = '';
    if ($parserExpanderMode eq 'passthrough') {
        if (m/^( *)<pre>parse/gs) {
            $parserExpanderState = {
                indent => $1,
                variables => {},
                actions => {},
                refs => {},
                mode => '',
                prefix => '',
                level => 0,
            };
            if (m/\G using /gs) {
                while (m/\G(.+?)(, |$)/gs) {
                    die if exists $parserExpanderState->{variables}->{$1};
                    $parserExpanderState->{variables}->{$1} = 1;
                }
            }
            $output .= "$parserExpanderState->{indent}<dl class=\"switch\">\n";
            $parserExpanderMode = 'parser';
        } else {
            $output .= "$_\n";
        }
    } elsif ($parserExpanderMode eq 'parser') {
        die unless $parserExpanderState;
        if (m/^$parserExpanderState->{indent}([^ ]+)ing to: (.+)$/s) {
            die if exists $parserExpanderState->{actions}->{$1};
            $parserExpanderState->{actions}->{$1} = $2;
        } elsif (m/^$parserExpanderState->{indent}switch using (.+)/s) {
            die if length $parserExpanderState->{mode};
            $parserExpanderState->{mode} = $1;
        } elsif (m/^$parserExpanderState->{indent}defined above: /gs) {
            while (m/\G(.+?)(, |$)/gs) {
                die if exists $parserExpanderState->{refs}->{$1};
                $parserExpanderState->{refs}->{$1} = 1;
            }
        } elsif (m/^$parserExpanderState->{indent}prefix xrefs with "(.+)"$/gs) {
            die if length $parserExpanderState->{prefix};
            $parserExpanderState->{prefix} = $1;
        } elsif (m/^$parserExpanderState->{indent}  case (.+):/s) {
            if ($parserExpanderState->{level} >= 3) {
                $output .= "$parserExpanderState->{indent}   </dd>\n";
            }
            if ($parserExpanderState->{level} >= 2) {
                $output .= "$parserExpanderState->{indent}  </dl>\n";
            }
            if ($parserExpanderState->{level} >= 1) {
                $output .= "$parserExpanderState->{indent} </dd>\n";
            }
            $output .= "$parserExpanderState->{indent} <dt>If <var data-x=\"$parserExpanderState->{prefix} $parserExpanderState->{mode}\">$parserExpanderState->{mode}</var> is \"<dfn data-x=\"$parserExpanderState->{prefix} $parserExpanderState->{mode}: $1\">$1</dfn>\"</dt>\n";
            $output .= "$parserExpanderState->{indent} <dd>\n";
            $parserExpanderState->{level} = 1;
        } elsif (m/^$parserExpanderState->{indent}    (.+?)=(.+?)(?: (?:(unless) (.+)|(if numbers are coming)|(if numbers are not coming)))?:/s) {
            my $var = $1;
            my $val = $2;
            my $parserExpanderMode = $3 || $5 || $6;
            my $flag = $4;
            die "unknown variable $var" unless $parserExpanderState->{variables}->{$var};
            die "unknown variable $flag" if defined $flag and not $parserExpanderState->{variables}->{$flag};
            die if $parserExpanderState->{level} < 1;
            if ($parserExpanderState->{level} >= 3) {
                $output .= "$parserExpanderState->{indent}   </dd>\n";
            } elsif ($parserExpanderState->{level} < 2) {
                $output .= "$parserExpanderState->{indent}  <p>Run the appropriate substeps from the following list:</p>\n";
                $output .= "$parserExpanderState->{indent}  <dl class=\"switch\">\n";
            }
            $val = expand($val);
            my $condition = "If <var>$var</var> is $val";
            if ($parserExpanderMode) {
                if ($parserExpanderMode eq 'unless') {
                    $condition .= " and <var>$flag</var> is false";
                } elsif ($parserExpanderMode eq 'if numbers are coming') {
                    $condition .= " and any of the characters in <var>value</var> past the <var>index</var>th character are <span>ASCII digits</span>";
                } elsif ($parserExpanderMode eq 'if numbers are not coming') {
                    $condition .= " and none of the characters in <var>value</var> past the <var>index</var>th character are <span>ASCII digits</span>";
                } else {
                    die "unknown token case conditional: '$parserExpanderMode'";
                }
            }
            $output .= "$parserExpanderState->{indent}   <dt>$condition</dt>\n";
            $output .= "$parserExpanderState->{indent}   <dd>\n";
            $parserExpanderState->{level} = 3;
        } elsif (m/^$parserExpanderState->{indent}    otherwise:/s) {
            die if $parserExpanderState->{level} < 2;
            if ($parserExpanderState->{level} >= 3) {
                $output .= "$parserExpanderState->{indent}   </dd>\n";
            }
            $output .= "$parserExpanderState->{indent}   <dt>Otherwise</dt>\n";
            $output .= "$parserExpanderState->{indent}   <dd>\n";
            $parserExpanderState->{level} = 3;
        } elsif (m/^$parserExpanderState->{indent}      (.+?) := (.+)/s) {
            my $var = $1;
            my $val = $2;
            die "unknown variable $var" unless $parserExpanderState->{variables}->{$var} or $parserExpanderState->{mode} eq $var;
            die if $parserExpanderState->{level} < 3;
            if ($parserExpanderState->{mode} eq $var) {
                $var = "<var data-x=\"$parserExpanderState->{prefix} $parserExpanderState->{mode}\">$var</var>";
                $val = "\"<span data-x=\"$parserExpanderState->{prefix} $parserExpanderState->{mode}: $val\">$val</span>\"";
            } else {
                $var = "<var>$var</var>";
                if ($parserExpanderState->{variables}->{$val}) {
                    $val = "the value of <var>$val</var>";
                } else {
                    die unless $val eq 'false' or $val eq 'true';
                }
            }
            $output .= "$parserExpanderState->{indent}    <p>Set $var to $val.</p>\n";
        } elsif ((m/^$parserExpanderState->{indent}      (.+?) (.+)/s) and ($parserExpanderState->{actions}->{$1})) {
            my $action = $1;
            my $var = $2;
            die "unknown variable $var" unless $parserExpanderState->{variables}->{$var};
            die if $parserExpanderState->{level} < 3;
            $var = "<var>$var</var>";
            $output .= "$parserExpanderState->{indent}    <p>Append $var to $parserExpanderState->{actions}->{$action}.</p>\n";
        } elsif (m/^$parserExpanderState->{indent}      (dec) (.+)/s) {
            my $action = $1;
            my $var = $2;
            die unless $parserExpanderState->{variables}->{$var};
            die if $parserExpanderState->{level} < 3;
            $var = "<var>$var</var>";
            $output .= "$parserExpanderState->{indent}    <p>Decrement $var by one.</p>\n";
        } elsif (m/^$parserExpanderState->{indent}      nop/s) {
            die if $parserExpanderState->{level} < 3;
            $output .= "$parserExpanderState->{indent}    <p>Do nothing.</p>\n";
        } elsif ((m/^$parserExpanderState->{indent}      (.+)/s) and ($parserExpanderState->{refs}->{$1})) {
            my $ref = $1;
            die if $parserExpanderState->{level} < 3;
            $output .= "$parserExpanderState->{indent}    <p><span data-x=\"$parserExpanderState->{prefix} $ref\">\u$ref</span>.</p>\n";
        } elsif (m/^$parserExpanderState->{indent}<\/pre>$/s) {
            if ($parserExpanderState->{level} >= 3) {
                $output .= "$parserExpanderState->{indent}   </dd>\n";
            }
            if ($parserExpanderState->{level} >= 2) {
                $output .= "$parserExpanderState->{indent}  </dl>\n";
            }
            if ($parserExpanderState->{level} >= 1) {
                $output .= "$parserExpanderState->{indent} </dd>\n";
            }
            $output .= "$parserExpanderState->{indent}</dl>\n";
            $parserExpanderMode = 'passthrough';
            $parserExpanderState = undef;
        } elsif (m/^$parserExpanderState->{indent}(  )*.+/s) {
            my $level = (length $1) / 2;
            die "syntax error in '$_' at level $level; you are actually at level $parserExpanderState->{level}";
        } else {
            die "syntax error in '$_'";
        }
    } else {
        die;
    }
    return $output;
}
