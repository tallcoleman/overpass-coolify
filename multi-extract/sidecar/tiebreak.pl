#!/usr/bin/perl
# Delete tie-break for merging OSM France region minute diffs.
#
# Usage: perl tiebreak.pl OUTDIR IN1.osc.gz [IN2.osc.gz ...]
#
# Writes OUTDIR/1.osc.gz, OUTDIR/2.osc.gz, ... (one per input, in input order).
# Each output is its input minus every <delete>d element whose type, id and
# version appear as a create or modify in any input. A region diff can delete an
# object at the same version that a neighbour has as modify (an artefact of how
# regions are cut), and a real OSM deletion always has a new version, so such a
# delete is never real. After this filter, `osmium merge-changes --simplify` of
# the outputs no longer depends on input order.
#
# Parses the line-oriented osmChange that OSM France publishes
# (generator="xmlwriter"): one element start tag per line, with child lines
# (nd, tag, member, bbox) up to </node|way|relation>. Dies on anything else,
# so a format change fails loudly instead of passing through unfiltered.
# Prints one line per dropped delete to stderr: "dropped <file> <type>/<id> v<version>".
use strict;
use warnings;
use IO::Uncompress::Gunzip qw($GunzipError);
use IO::Compress::Gzip qw($GzipError);

die "usage: $0 OUTDIR IN.osc.gz...\n" unless @ARGV >= 2;
my ($outdir, @inputs) = @ARGV;
die "$0: $outdir is not a directory\n" unless -d $outdir;

# Calls $cb->($line, $action, $key) for every line of an osmChange file.
# $action is create/modify/delete inside an action block, else undef.
# $key is "type/id/version" on the lines of an element (start tag through
# end tag), else undef.
sub scan {
    my ($path, $cb) = @_;
    my $in = IO::Uncompress::Gunzip->new($path, MultiStream => 1)
        or die "$0: $path: $GunzipError\n";
    my ($action, $key, $open, $seen_root, $closed_root);
    while (defined(my $line = $in->getline)) {
        my $t = $line;
        $t =~ s/^\s+|\s+$//g;
        my $lineno = $in->input_line_number;
        my $bad = sub { die "$0: $path:$lineno: unexpected line: $t\n" };
        if ($t eq '') {
            # blank lines are harmless
        } elsif (defined $open) {
            # inside a multi-line element
            if ($t eq "</$open>") {
                $cb->($line, $action, $key);
                undef $open;
                undef $key;
                next;
            }
            $t =~ m{^<(?:nd|tag|member|bbox)\s.*/>$} or $bad->();
        } elsif (defined $action) {
            if ($t eq "</$action>") {
                undef $action;
            } elsif ($t =~ m{^<(node|way|relation)\s(.*?)(/?)>$}) {
                my ($type, $attrs, $selfclose) = ($1, $2, $3);
                my ($id) = $attrs =~ /(?:^|\s)id="(-?\d+)"/;
                my ($ver) = $attrs =~ /(?:^|\s)version="(\d+)"/;
                defined $id && defined $ver or $bad->();
                $key = "$type/$id/$ver";
                if ($selfclose) {
                    $cb->($line, $action, $key);
                    undef $key;
                    next;
                }
                $open = $type;
            } else {
                $bad->();
            }
        } elsif ($t =~ m{^<\?xml\s.*\?>$}) {
            # XML declaration
        } elsif (!$seen_root && $t =~ m{^<osmChange(\s.*)?>$}) {
            $seen_root = 1;
        } elsif ($seen_root && !$closed_root && $t =~ m{^<(create|modify|delete)\s*(/?)>$}) {
            $action = $1 unless $2;
        } elsif ($seen_root && !$closed_root && $t eq '</osmChange>') {
            $closed_root = 1;
        } else {
            $bad->();
        }
        $cb->($line, $action, $key);
    }
    $in->close;
    die "$0: $path: truncated (no </osmChange>)\n" unless $closed_root;
}

# Pass 1: every create/modify key in any input.
my %live;
for my $path (@inputs) {
    scan($path, sub {
        my (undef, $action, $key) = @_;
        $live{$key} = 1 if defined $key && $action ne 'delete';
    });
}

# Pass 2: copy each input, dropping tied deletes.
my $n = 0;
for my $path (@inputs) {
    $n++;
    my $final = "$outdir/$n.osc.gz";
    my $tmp = "$final.tmp";
    my $out = IO::Compress::Gzip->new($tmp) or die "$0: $tmp: $GzipError\n";
    my %reported;
    scan($path, sub {
        my ($line, $action, $key) = @_;
        if (defined $key && $action eq 'delete' && $live{$key}) {
            my ($type, $id, $ver) = split m{/}, $key;
            print STDERR "dropped $path $type/$id v$ver\n" unless $reported{$key}++;
            return;
        }
        $out->print($line) or die "$0: $tmp: write failed\n";
    });
    $out->close or die "$0: $tmp: $GzipError\n";
    rename $tmp, $final or die "$0: rename $tmp: $!\n";
}
