#!/usr/bin/perl -w
use strict;

my $seenInsertionPoint = 0;
my $after = '';

my %definitions;
my $inpre = 0;
while (<>) {
    $inpre = 1 if /<pre class="idl">/os;
    if ($inpre && /(partial )?interface <(span|dfn|a href=#[^ >]*)( id="?([^ ">]*)"?)?[^>]*>([^<:]*)?<\/(span|dfn|a)>/os) {
        my $partial = $1;
        my $id;
        my $name;
        if ($partial) {
            if ($4) {
                ($id, $name) = ($4, $5);
            } else {
                if ($5 eq 'HTMLSourceElement') {
                    ($id, $name) = ('the-source-element-when-used-with-the-picture-element:htmlsourceelement', $5);
                } elsif ($5 eq 'XMLDocument') {
                    ($id, $name) = ('loading-xml-documents:xmldocument', $5);
                } else {
                    die "don't know how to create partial interface entry for $name in All Interfaces index";
                }
            }
            $definitions{$name} = { } unless defined $definitions{$name};
            $definitions{$name}{partial} = [] unless exists $definitions{$name}{partial};
            push @{$definitions{$name}{partial}}, $id;
        } else {
            if ($5 ne 'HTMLBaseFontElement') {
                $name = $5;
                $definitions{$name} = { } unless defined $definitions{$name};
                die "duplicate interface definitions for $name" if exists $definitions{$name}{primary};
            }
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
    print "   <li><code>$name</code>";
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
