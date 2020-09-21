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
    } elsif ($line =~ m!^( *)(<pre[^>]*>(?:<code[^>]*>)?)EXAMPLE (offline/|workers/|canvas/)((?:[-a-z0-9]+/){1,2}[-a-z0-9]+.[-a-z0-9]+)((?:</code>)?</pre>) *\n$!os) {
        my $indent = $1;
        my $starttags = $2;
        my $folder = $3;
        my $example = $4;
        my $endtags = $5;

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
        unshift @lines, split("\n", "$indent$starttags$data$endtags");
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

    # This seems to be necessary due to the file substitutions, for some reason.
    $line = normalizeNewlines($line);

    print "$line";
}
report "\n";

sub normalizeNewlines {
    $_ = shift;
    chomp;
    return "$_\n";
}
