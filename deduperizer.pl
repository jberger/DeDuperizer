#!/usr/bin/env perl

use v5.18;
use warnings;

use constant DEBUG => $ENV{DEDUP_DEBUG};
use constant QUICK => $ENV{DEDUP_QUICK} // 1;
BEGIN { $ENV{DEDUP_PROGRESS} //= not QUICK }

$|++;
use DDP;
use File::Next;
use File::Map 'map_file';
use Digest::xxHash 'xxhash';
use List::Util 'first';

use constant PROGRESS => $ENV{DEDUP_PROGRESS} ? eval <<'END' : 0;
use Progress::Any;
use Progress::Any::Output;
Progress::Any::Output->set('TermProgressBarColor');
1;
END

my $target = shift || '/dedup';
my @inodes;

my $opts = { 
  follow_symlinks => 0,
  error_handler => sub { CORE::warn @_ },
};
my $iter = File::Next::files($opts, $target);

say 'Checking sizes' if DEBUG;

my %sizes;
while ( defined ( my $file = $iter->() ) ) {
  my ($inode, $nlinks) = (lstat $file)[1,3];
  if ($nlinks and $nlinks > 1) {
    next if first { $_ == $inode } @inodes;
    push @inodes, $inode;
  }
  push @{ $sizes{-s $file} }, $file;
}

say 'Checking file contents' if DEBUG;

sub myhash {
  my $file = shift;
  map_file my $map, $file, '<';
  my $hash = xxhash($map, 0);
  say "Hashed: $file ==> $hash" if DEBUG;
  return $hash;
}

sub montecarlo {
  my ($file, $size) = @_;
  map_file my $map, $file, '<';

  my $l = 20;
  my @points = map { int( $_ * $size ) } (0, 0.3, 0.6);
  push @points, -$l;

  return "$map" if $size < ($l * @points);

  my $mc;
  $mc .= substr $map, $_, $l for @points;
  say "Monte Carlo: $file ==> $mc" if DEBUG;
  return $mc;
}

my $progress;
if (PROGRESS) {
  my $njobs;
  $njobs += scalar @$_ for values %sizes;
  $progress = Progress::Any->get_indicator(target => $njobs);
}

my %candidates;
foreach my $size (keys %sizes) {
  my $files = $sizes{$size};
  next unless @$files > 1;

  for my $file (@$files) {
    my $hash = eval { QUICK ? montecarlo($file, $size) : myhash($file, $size) };
    warn $@ if $@;
    say "Stored: $file ==> $hash" if DEBUG;
    push @{ $candidates{"$size-$hash"} }, $file;
    $progress->update if PROGRESS;
  }
}

$progress->finish if PROGRESS;

my @candidates = grep { @$_ > 1 } values %candidates;
p @candidates;

my $num;
$num += scalar @$_ for @candidates;
say "Total files: $num";

