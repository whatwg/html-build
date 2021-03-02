#!/usr/bin/perl -w
use strict;
use v5.10.0;

my $state = undef;

my $mode = 'bored';
my %attributes = ();
my @lines = ();
my %instances = ();
while (defined($_ = <>)) {
    my $line = \"$_";
    push(@lines, $line);
    if ($_ eq "  <h3 class=\"no-num\">Attributes</h3>\n") {
         $mode = 'index';
    } else {
        if ($mode eq 'bored') {
            if ($_ eq "   <dt><span data-x=\"concept-element-attributes\">Content attributes</span>:</dt>\n") {
                $mode = 'element';
            }
        } elsif ($mode eq 'element') {
            if ($_ eq "   <dd><span>Global attributes</span></dd>\n") {
                # ignore
            } elsif ($_ =~ m!^   <dd>.*<code data-x="((?:attr-|handler-)[^"]+)">.+</code>(.*)</dd>\n$!os) {
                my $key = $1;
                my $notes = $2;
                my $special = '';
                $special = 'global' if $notes =~ m!special semantics!os;
                $special = 'alt' if $notes =~ m@<!-- variant -->@os;
                if (not exists $instances{$key}) {
                    $instances{$key} = [];
                }
                if ($notes !~ m@<!-- no-annotate -->@os) {
                    push(@{$instances{$key}}, { line => $line, special => $special });
                }
            } elsif ($_ =~ m/^   <!--.*-->\n$/os) {
                # ignore
            } elsif ($_ eq "   <dd>Any other attribute that has no namespace (see prose).</dd>\n") {
                # ignore
            } elsif ($_ =~ m!^   <dt>!o) {
                $mode = 'bored';
            } else {
                # ignore
            }
        } elsif ($mode eq 'index') {
            if ($_ eq "  </table>\n") {
                $mode = 'end';
            } elsif ($_ eq "    <tr>\n") {
                $mode = 'tr';
            } else {
                # ignore...
            }
        } elsif ($mode eq 'tr') {
            if ($_ =~ m!^     <td> <(?:code|span) data-x="([^"]+)">[^<]*</(?:code|span)>(?: \(in [^\)]+\))?;?\n$!os) {
                $attributes{$1} = 1;
                $mode = 'index-in';
            } else {
                # ignore...
            }
        } elsif ($mode eq 'index-in') {
            if ($_ =~ m!^          <(?:code|span) data-x="([^"]+)">[^<]*</(?:code|span)>(?: \(in [^\)]+\))?;?\n$!os) {
                $attributes{$1} = 1;
            } elsif ($_ =~ m@^     <td> (.+?)(?:<!--or: (.+)-->)?\n$@os) {
                local $" = ', ';
                my $description = $1;
                my $altdescription = $2;
                foreach my $key (keys %attributes) {
                    foreach my $entry (@{$instances{$key}}) {
                        my $line = $entry->{line};
                        if ($entry->{special} eq 'global') {
                            $$line =~ s!(\.</dd>\n)$!: $description<\!--SPECIAL-->$1!os;
                            $$line =~ s!<\!--SPECIAL-->: *([^ ])!; \l$1!os;
                        } elsif ($entry->{special} eq 'alt') {
                            die "$key wants alt description but we have none" unless defined $altdescription;
                            $$line =~ s!(</dd>\n)$! &mdash; $altdescription$1!os;
                        } else {
                            $$line =~ s!(</dd>\n)$! &mdash; $description$1!os;
                        }
                    }
                }
                %attributes = ();
                $mode = 'index';
            } else {
                die "$.: unexpected line in index: $_";
            }
        } else {
            # ignore
        }
    }
}

foreach (@lines) {
    $$_ =~ s/<!--SPECIAL-->//gos;
    print $$_;
}
