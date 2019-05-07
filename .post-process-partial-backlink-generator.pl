#!/usr/bin/perl -w
use strict;

my @lines = ();

my %definitions;
my $inpre = 0;
while (<>) {
    $inpre = 1 if /<pre><code class='idl'>/os;
    if ($inpre && /(<c- b>partial<\/c-> )?<c- b>interface<\/c-> <(?:span|dfn|a href='#[^ >]*')(?: data-lt[^ ]*)? id='([^ >]*)'.*?><c- g>([^<:]*)?<\/c-><\/(span|dfn|a)>/os) {
        my ($partial, $id, $name) = ($1, $2, $3);
        my $notobs = 0; # XXX we can use this to avoid implying a partial interface is obsolete. Unused at the moment.
        $definitions{$name} = { } unless defined $definitions{$name};
        if ($partial) {
            $definitions{$name}{partial} = [] unless exists $definitions{$name}{partial};
            push @{$definitions{$name}{partial}}, { name => $id, obsolete => ($notobs ? 0 : 1)};
        } else {
            die "duplicate interface definitions for $name" if exists $definitions{$name}{primary};
            $definitions{$name}{primary} = $id;
        }
    }
    $inpre = 0 if /<\/code><\/pre>/os;
    push(@lines, $_);
}

die if $inpre;

my $current = '';
foreach (@lines) {
    $inpre = 1 if /<pre><code class='idl'>/os;
    if ($inpre) {
        if (/(<c- b>partial<\/c-> )?<c- b>interface<\/c-> <(?:span|dfn|a href='#[^ >]*')(?: data-lt[^ ]*)? id='([^ >]*)'.*?><c- g>([^<:]*)?<\/c-><\/(span|dfn|a)>/os) {
            my ($partial, $id, $name) = ($1, $2, $3);
            die if $current;
            $current = $name unless $partial;
        }
        if (/^(.*)(\};.*)$/os and $current) {
            if ($definitions{$current}{partial}) {
                die "we don't yet handle multiple partials" if @{$definitions{$current}{partial}} > 1;
                my $id = $definitions{$current}{partial}[0]->{name};
                if ($definitions{$current}{partial}[0]->{obsolete}) {
                    $_ = "$1\n  // <a href=\"#$id\">also has obsolete members</a>\n$2";
                } else {
                    $_ = "$1\n  // <a href=\"#$id\">also has additional members in a partial interface</a>\n$2";
                }
            }
            $current = '';
        }
    }
    $inpre = 0 if /<\/code><\/pre>/os;
    print $_;
}
