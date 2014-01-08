#!/usr/bin/env perl

use v5.10;
use warnings;
use Getopt::Long;
use constant;

BEGIN {
  my $debug = 0;
  my $human = 0;
  my $progress = 0;
  my $quick = 0;

  GetOptions (
    debug    => \$debug,
    human    => \$human,
    progress => \$progress,
    quick    => \$quick,
  );

  constant->import( DEBUG => $debug );
  constant->import( HUMAN => $human );
  constant->import( QUICK => $quick );

  constant->import( PROGRESS => $progress ? eval <<'  END' : 0 );
    use Progress::Any;
    use Progress::Any::Output;
    Progress::Any::Output->set('TermProgressBarColor');
    1;
  END
}

use File::Next;
use File::Map 'map_file';
use Digest::xxHash 'xxhash';

sub get_files_by_inode {
  my $target = shift;
  my $opts = shift || { 
    follow_symlinks => 0,
    error_handler => sub { CORE::warn @_ },
  };

  my $iter = File::Next::files($opts, $target);

  my %inodes;
  while ( defined ( my $file = $iter->() ) ) {
    my $inode = (lstat $file)[1];
    push @{ $inodes{$inode} }, $file;
  }

  return \%inodes;
}

sub group_files_by_size {
  my $files = shift || [];
  my %sizes;
  foreach my $file (@$files) {
    push @{ $sizes{-s $file} }, $file;
  }
  return \%sizes;
}

sub hash_file {
  my ($file, $size) = @_;
  return '' unless $size;
  map_file my $map, $file, '<';
  my $hash = xxhash($map, 0);
  warn "Hashed: $file ==> $hash\n" if DEBUG;
  return $hash;
}

sub montecarlo_file {
  my ($file, $size) = @_;
  return '' unless $size;
  map_file my $map, $file, '<';

  my $l = 20;
  my @points = map { int( $_ * $size ) } (0, 0.3, 0.6);
  push @points, -$l;

  return "$map" if $size < ($l * @points);

  my $mc;
  $mc .= substr $map, $_, $l for @points;
  warn "Monte Carlo: $file ==> $mc\n" if DEBUG;
  return $mc;
}

my $target = shift || '/dedup';

my $sizes = do {
  warn "Getting unique inodes\n" if DEBUG;
  my $inode_files = get_files_by_inode($target);
  my @files = map { (sort @$_)[0] } values %$inode_files;

  warn "Checking sizes\n" if DEBUG;
  group_files_by_size(\@files);
};

warn "Checking file contents\n" if DEBUG;

my $progress;
if (PROGRESS) {
  my $njobs;
  $njobs += scalar @$_ for values %$sizes;
  $progress = Progress::Any->get_indicator(target => $njobs);
}

my %candidates;
foreach my $size (keys %$sizes) {
  my $files = $sizes->{$size};
  next unless @$files > 1;

  for my $file (@$files) {
    my $hash = eval { QUICK ? montecarlo_file($file, $size) : hash_file($file, $size) };
    warn $@ if $@;
    warn "Stored: $file ==> $hash\n" if DEBUG;
    push @{ $candidates{"$size-$hash"} }, $file;
    $progress->update if PROGRESS;
  }
}

$progress->finish if PROGRESS;

warn "Formatting output\n" if DEBUG;
my @candidates = 
  sort { $a->[0] cmp $b->[0] } 
  map  { [ sort @$_ ] }
  grep { @$_ > 1 } 
  values %candidates;

if (HUMAN) {
  require Data::Printer;
  Data::Printer::p( @candidates );
  say 'Total sets ' . @candidates;
  my $num;
  $num += scalar @$_ for @candidates;
  say "Total files: $num";
} else {
  local $, = "\t";
  say @$_ for @candidates;
}


