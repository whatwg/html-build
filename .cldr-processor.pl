#!/usr/bin/perl -wT
use strict;
use XML::Parser;

my $quiet = $ARGV[0] && '--quiet' eq "$ARGV[0]" ? 'true' : 'false';

my $parser = XML::Parser->new(Style => 'Tree');

my $delimiters = {};

my @filenames = <$ENV{'HTML_CACHE'}/cldr-data/*.xml>;
my $count = 0;
for my $filename (@filenames) {
    $count += 1;
    $filename =~ m|/([0-9a-zA-Z_]+)\.xml$|os or die "Unexpected filename syntax: $filename\n";
    my $language = $1;
    $language =~ s/_/-/os;
    print STDERR sprintf "Reading  %-35s    %3d%%\r", $filename, (100 * $count / (scalar @filenames)) if "false" eq $quiet;
    my $tree = tweak($parser->parsefile($filename));
    next unless ref $tree->{ldml}->{delimiters};
    if (scalar keys %{$tree->{ldml}->{delimiters}} > 0) {
        $delimiters->{$language} = $tree->{ldml}->{delimiters};
    }
}

print STDERR "Processing...                                          \r" if "false" eq $quiet;

for my $language (sort { $a eq 'root' ? -1 : $b eq 'root' ? 1 : $a cmp $b } keys %$delimiters) {
    my $q1a = escape(getDelimiter($language, 'quotationStart'));
    my $q1b = escape(getDelimiter($language, 'quotationEnd'));
    my $q2a = escape(getDelimiter($language, 'alternateQuotationStart'));
    my $q2b = escape(getDelimiter($language, 'alternateQuotationEnd'));
    my $selector;
    if ($language eq 'root') {
        $selector = ':root';
    } else {
        $selector = sprintf('%-21s %s', ":root:lang($language),", ":not(:lang($language)) > :lang($language)");
    }
    printf "%-61s { quotes: '\\$q1a' '\\$q1b' '\\$q2a' '\\$q2b' } /* &#x$q1a; &#x$q1b; &#x$q2a; &#x$q2b; */\n", $selector if "false" eq $quiet;
}

print STDERR "Done.                                                  \n" if "false" eq $quiet;

sub getDelimiter {
    my($originalLanguage, $key) = @_;
    my $language = $originalLanguage;
    while ($language) {
        if (exists $delimiters->{$language}->{$key}) {
            return $delimiters->{$language}->{$key};
        }
        if ($language =~ m/-/os) {
            $language =~ s/-[^-]+$//os;
        } elsif ($language ne 'root') {
            $language = 'root';
        } else {
            last;
        }
    }
    warn "Couldn't find $key character for $originalLanguage.\n";
    return '"';
}

sub tweak {
    my($data) = @_;
    my $output = {};
    while (@$data) {
        my $tagname = shift @$data;
        my $contents = shift @$data;
        if ($tagname) {
            if (exists $contents->[0]->{draft} and $contents->[0]->{draft} ne 'approved') {
                next; # drop draft data
            }
            shift @$contents; # drops attributes on the floor
            $output->{$tagname} = tweak($contents);
        } else {
            if ($contents =~ m/[^ \t\n]/os) {
                # drop whitespace text nodes and any nodes that precede a non-whitespace text node
                warn "losing data" if not ref $output or scalar keys %$output;
                $output = $contents;
            }
        }
    }
    return $output;
}

sub escape {
    my($data) = @_;
    my $s = '';
    foreach (split //, $data) {
        $s .= sprintf "%04x", ord $_;
    }
    return $s;
}
