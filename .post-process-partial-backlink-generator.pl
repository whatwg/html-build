#!/usr/bin/perl -w
use strict;

my @lines = ();

my %definitions;
my $inpre = 0;
while (<>) {
    $inpre = 1 if /<pre class=idl>/os;
    if ($inpre && /(partial )?interface <(span|dfn|a href=#[^ >]*) id=([^ >]*).*?>([^<:]*)?<\/(span|dfn|a)>(.*<!-- not obsolete -->)?/os) {
        my ($partial, $id, $name, $notobs) = ($1, $3, $4, $6);
        $notobs = $name eq 'WorkerGlobalScope'; # XXX hack for now
        $definitions{$name} = { } unless defined $definitions{$name};
        if ($partial) {
            $definitions{$name}{partial} = [] unless exists $definitions{$name}{partial};
            push @{$definitions{$name}{partial}}, { name => $id, obsolete => ($notobs ? 0 : 1)};
        } else {
            die "duplicate interface definitions for $name" if exists $definitions{$name}{primary};
            $definitions{$name}{primary} = $id;
        }
    }
    $inpre = 0 if /<\/pre>/os;
    push(@lines, $_);
}

die if $inpre;

my $current = '';
foreach (@lines) {
    $inpre = 1 if /<pre class=idl>/os;
    if ($inpre) {
        if (/(partial )?interface <(span|dfn|a href=#[^ >]*) id=([^ >]*).*?>([^<:]*)?<\/(span|dfn|a)>/os) {
            my ($partial, $id, $name) = ($1, $3, $4);
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
    $inpre = 0 if /<\/pre>/os;
    print $_;
}
