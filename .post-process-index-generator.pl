#!/usr/bin/perl -w
use strict;

my $seenInsertionPoint = 0;
my $after = '';

my %definitions;
my $inpre = 0;
while (<>) {
    $inpre = 1 if /<pre class=idl>/os;
    if ($inpre && /(partial )?interface <(span|dfn|a href=#[^ >]*) id=([^ >]*).*?>([^<:]*)?<\/(span|dfn|a)>/os) {
        my ($partial, $id, $name) = ($1, $3, $4);
        $definitions{$name} = { } unless defined $definitions{$name};
        if ($partial) {
            $definitions{$name}{partial} = [] unless exists $definitions{$name}{partial};
            push @{$definitions{$name}{partial}}, $id;
        } else {
            die "duplicate interface definitions for $name" if exists $definitions{$name}{primary};
            $definitions{$name}{primary} = $id;
        }
    }
    $inpre = 0 if /<\/pre>/os;
    if (/^INSERT INTERFACES HERE\n?$/os) {
        $seenInsertionPoint = 1;
    } else {
        if ($seenInsertionPoint) {
            $after .= $_;
        } else {
            print $_;
        }
    }
}

die unless $seenInsertionPoint;

print "  <ul class=\"brief\">\n";
for my $name (sort keys %definitions) {
    print "   <li><code>";
    if (exists $definitions{$name}{primary}) {
        print "<a href=#$definitions{$name}{primary}>$name</a>";
    } else {
        print $name;
    }
    print "</code>";
    if (exists $definitions{$name}{partial}) {
        print ", <a href=#$definitions{$name}{partial}[0]>partial";
        print " 1" if @{$definitions{$name}{partial}} > 1;
        print "</a>";
        for (my $i = 1; $i < @{$definitions{$name}{partial}}; $i++) {
            print " <a href=#$definitions{$name}{partial}[$i]>$i</a>";
        }
    }
    print "\n";
}
print "  </ul>\n";
print $after;
