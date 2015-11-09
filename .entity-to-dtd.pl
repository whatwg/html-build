#!/usr/bin/perl -wT
use strict;

sub escape($) { ($_[0] eq "26" || $_[0] eq "3C" ? "&#x26;" : "&") . "#x$_[0];" }

# read dtd
my $dtd = '';
while (<>) {
    if (m(<tr(?: id="[^"]+")?> <td> <code data-x="">(.+?);</code> </td> <td> U\+0*([0-9A-F]+) </td>)os) {
        $dtd .= "<!ENTITY $1 \"".escape($2)."\">";
    } elsif (m(<tr(?: id="[^"]+")?> <td> <code data-x="">(.+?);</code> </td> <td> U\+0*([0-9A-F]+) U\+0*([0-9A-F]+) </td>)os) {
        $dtd .= "<!ENTITY $1 \"".escape($2).escape($3)."\">";
    } else {
        die "$0: line doesn't match pattern:\n$_\n";
    }
}

#warn "$dtd\n";
#exit;

# output data: URL
use HTML::Entities;
use MIME::Base64;
use URI::Escape;

my $data = uri_escape(encode_base64($dtd, ''));

print "data:application/xml-dtd;base64,$data";
