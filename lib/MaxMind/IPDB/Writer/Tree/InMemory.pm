package MaxMind::IPDB::Writer::Tree::InMemory;

use strict;
use warnings;

use Carp qw( confess );
use Digest::MD5 qw( md5 );
use JSON::XS;
use List::Util qw( min );
use MaxMind::IPDB::Common qw( LEFT_RECORD RIGHT_RECORD );
use Scalar::Util qw( blessed );

use Moose;
use MooseX::StrictConstructor;

# We intentionally access most of these attributes by calling $self->{...}
# rather than using accessors, but declaring them makes it easy to provide a
# default and provides a little bit of documentation on their types.
has _data_index => (
    is       => 'ro',
    isa      => 'HashRef[Any]',
    init_arg => undef,
    default  => sub { {} },
);

has _node_buffers => (
    is       => 'ro',
    isa      => 'ArrayRef[Str]',
    init_arg => undef,
    default  => sub { [] },
);

has _allocated_node_count => (
    is       => 'ro',
    isa      => 'Int',
    init_arg => undef,
    default  => 0,
);

has root_node_num => (
    is       => 'ro',
    writer   => '_set_root_node_num',
    isa      => 'Int',
    init_arg => undef,
);

has _used_node_count => (
    is       => 'ro',
    isa      => 'Int',
    init_arg => undef,
    default  => 0,
);

has _insert_cache => (
    is       => 'ro',
    isa      => 'HashRef',
    init_arg => undef,
    default  => sub { {} },
);

use constant {
    _RECORD_SIZE          => 16,
    _NODES_PER_ALLOCATION => 2**16,
};

use constant {
    _NODE_POINTER_MASK => _NODES_PER_ALLOCATION - 1,
    _NODE_SIZE         => _RECORD_SIZE * 2,
};

sub BUILD {
    my $self = shift;

    $self->_set_root_node_num( $self->_next_node_num() );

    return;
}

sub _allocate_more_nodes {
    my $self = shift;

    my $new_nodes = "\0" x ( _NODES_PER_ALLOCATION * _NODE_SIZE );
    push @{ $self->{_node_buffers} }, \$new_nodes;
    $self->{_allocated_node_count} += _NODES_PER_ALLOCATION;
}

sub _next_node_num {
    my $self = shift;

    $self->_allocate_more_nodes()
        unless $self->{_used_node_count} < $self->{_allocated_node_count};

    return $self->{_used_node_count}++;
}

sub get_record {
    my $self = shift;

    confess "2 args required" if @_ != 2;
    return $self->_record(@_);
}

sub set_record {
    my $self = shift;

    confess "3 args required" if @_ != 3;
    return $self->_record(@_);
}

sub _record {
    my $self      = shift;
    my $node      = shift;
    my $direction = shift;
    my $record    = shift;

    my $ptr_idx = $node >> _RECORD_SIZE;

    my $byte_pos = ( $node & _NODE_POINTER_MASK ) * _NODE_SIZE;
    my $pos      = $byte_pos + $direction * _RECORD_SIZE;
    my $length   = _RECORD_SIZE;

    die "Invalid node # ($node)"
        unless defined $self->{_node_buffers}[$ptr_idx]
        && length ${ $self->{_node_buffers}[$ptr_idx] } >= $pos + $length;

    if ( !$record ) {
        return substr( ${ $self->{_node_buffers}[$ptr_idx] }, $pos, $length );
    }

    substr( ${ $self->{_node_buffers}[$ptr_idx] }, $pos, $length ) = $record;

    return;
}

sub record_is_empty {
    $_[1] eq "\0" x 16;
}

sub record_pointer_value {
    return unless substr( $_[1], 4 ) eq 'POINTER_RECD';
    return unpack( N => $_[1] );
}

sub mk_pointer_record {
    return pack( NA12 => $_[1], 'POINTER_RECD' );
}

sub node_count {
    return $_[0]->_used_node_count();
}

# This turns out to be faster than using Storable.
my $Encoder = JSON::XS->new()->utf8()->allow_nonref();

sub insert_subnet {
    my $self   = shift;
    my $subnet = shift;
    my $data   = shift;

    $self->{_saw_ipv6} ||= $subnet->version() == 6;

    my $key = md5( $Encoder->encode($data) );
    $self->{_data_index}{$key} ||= $data;

    my $ipnum = $subnet->first()->as_integer();

    my ( $node, $idx, $node_netmask, $bit_to_check )
        = $self->_find_cached_node($subnet);

    my $cache = $self->_insert_cache();
    $cache->{last_ipnum}   = $ipnum;
    $cache->{last_netmask} = $subnet->netmask_as_integer();

    local $self->{_needs_move} = {};

    while ( --$node_netmask ) {
        $cache->{node_num_cache}[ $idx++ ] = $node;

        my $direction = $self->_direction( $ipnum, $bit_to_check );
        my $record = $self->get_record( $node, $direction );

        if ( my $next_node = $self->record_pointer_value($record) ) {
            $node = $next_node;
        }
        else {
            $node = $self->_make_new_node(
                $node,
                $direction,
                $record,
                $ipnum,
                $subnet,
                $node_netmask,
            );
        }

        $bit_to_check >>= 1;
    }

    $cache->{node_num_cache}[$idx] = $node;

    my $direction = $self->_direction( $ipnum, $bit_to_check );

    $self->set_record( $node, $direction, $key );

    for my $subnet ( @{ $self->{_needs_move}{subnets} } ) {
        $self->insert_subnet( $subnet, $self->{_needs_move}{data} );
    }
}

sub _find_cached_node {
    my $self   = shift;
    my $subnet = shift;

    my $netmask = $subnet->netmask_as_integer();

    my $mask_length  = $subnet->mask_length();
    my $default_mask = $self->_all_ones_mask($mask_length);

    my $cache = $self->_insert_cache();

    my $cached_ipnum = $cache->{last_ipnum};

    return ( $self->root_node_num(), 0, $netmask, $default_mask )
        if $ENV{MAXMIND_IPDB_WRITER_NO_CACHE} || ! $cached_ipnum;

    my $one_idx = $self->_first_shared_bit(
        $subnet->first()->as_integer(),
        $cached_ipnum,
    );

    my $cache_idx = min(
        ( ( $one_idx >= 0 ) ? $one_idx : $mask_length - 1 ),
        $netmask - 1,
        $cache->{last_netmask} - 1
    );

    return (
        $cache->{node_num_cache}[$cache_idx] || $self->root_node_num(),
        $cache_idx,
        $netmask - $cache_idx,
        $default_mask >> $cache_idx,
    );
}

# Finds the position (as a count of bits) of the first 1 that is in both the
# cached number and the number we're inserting.
sub _first_shared_bit {
    my $self   = shift;
    my $ipnum1 = shift;
    my $ipnum2 = shift;

    my $xor_ipnum = $ipnum1 ^ $ipnum2;
    my $string;

    if ( blessed($xor_ipnum) ) {
        my $bin = $xor_ipnum->as_bin();

        $bin =~ s/^0b//;
        $string = sprintf( '%128s', $bin );
    }
    else {
        $string = sprintf( '%32b', $xor_ipnum );
    }

    return index( $string, '1' );
}

sub _all_ones_mask {
    my $self = shift;
    my $bits = shift;

    return 2**31 if $bits == 32;

    use bigint;
    return 2**127;
}

sub _direction {
    my $self         = shift;
    my $ipnum        = shift;
    my $bit_to_check = shift;

    return $bit_to_check & $ipnum ? RIGHT_RECORD : LEFT_RECORD;
}

sub _make_new_node {
    my $self         = shift;
    my $node         = shift;
    my $direction    = shift;
    my $record       = shift;
    my $ipnum        = shift;
    my $subnet       = shift;
    my $node_netmask = shift;

    my $new_node   = $self->_next_node_num;
    my $new_record = $self->mk_pointer_record($new_node);
    $self->set_record( $node, $direction, $new_record );

    unless ( $self->record_is_empty($record) ) {
        $self->{_needs_move}{subnets} = $self->_split_node(
            $ipnum,
            $subnet->netmask_as_integer(),
            $node_netmask,
            $subnet->version()
        );

        $self->{_needs_move}{data} = $self->{_data_index}{$record};
    }

    return $new_node;
}

sub _split_node {
    my $self           = shift;
    my $start_ipnum    = shift;
    my $subnet_netmask = shift;
    my $node_netmask   = shift;
    my $version        = shift;

    my $bits = $version == 6 ? 128 : 32;

    my $old_start_ipnum;
    my $old_end_ipnum;
    my $end_ipnum;

    {
        use bigint;
        my $t = ~0 << ( $bits - $subnet_netmask + $node_netmask );
        $old_start_ipnum = $start_ipnum & $t;
        $old_end_ipnum   = ~$t + $old_start_ipnum;
        $end_ipnum = $start_ipnum | ~( ~0 << ( $bits - $subnet_netmask ) );
    }

    my @subnets;
    if ( $old_start_ipnum < $start_ipnum ) {
        @subnets = MM::Net::Subnet->range_as_subnets(
            MM::Net::IPAddress->new_from_integer(
                integer => $old_start_ipnum,
                version => $version,
            ),
            MM::Net::IPAddress->new_from_integer(
                integer => $start_ipnum - 1,
                version => $version,
            )
        );
    }

    if ( $old_end_ipnum > $end_ipnum ) {
        push @subnets,
            MM::Net::Subnet->range_as_subnets(
            MM::Net::IPAddress->new_from_integer(
                integer => $end_ipnum + 1,
                version => $version,
            ),
            MM::Net::IPAddress->new_from_integer(
                integer => $old_end_ipnum,
                version => $version,
            ),
            );
    }

    return \@subnets;
}

sub iterate {
    my $self              = shift;
    my $object            = shift;
    my $starting_node_num = shift || $self->root_node_num();

    my $ip_integer = 0;

    my $iterator = $self->_make_iterator($object);

    $iterator->($starting_node_num);

    return;
}

sub _make_iterator {
    my $self   = shift;
    my $object = shift;

    my $max_netmask = $self->{_saw_ipv6} ? do { use bigint; 128 } : 32;

    my $iterator;
    $iterator = sub {
        no warnings 'recursion';
        my $node_num = shift;
        my $ip_num   = shift || 0;
        my $netmask  = shift || 1;

        my @directions = $object->directions_for_node($node_num);

        my %records
            = map { $_ => $self->get_record( $node_num, $_ ) } @directions;

        return
            unless $object->process_node(
            $node_num,
            \%records,
            $ip_num,
            $netmask,
            );

        for my $dir (@directions) {
            my $value = $records{$dir};

            my $next_ip_num
                = $dir
                ? $ip_num + ( 2**( $max_netmask - $netmask ) )
                : $ip_num;

            if ( my $pointer = $self->record_pointer_value($value) ) {
                return
                    unless $object->process_pointer_record(
                    $node_num,
                    $dir,
                    $pointer,
                    $ip_num,
                    $netmask,
                    $next_ip_num,
                    $netmask + 1
                    );

                $iterator->( $pointer, $next_ip_num, $netmask + 1 );
            }
            elsif ( $self->record_is_empty($value) ) {
                return
                    unless $object->process_empty_record(
                    $node_num,
                    $dir,
                    $ip_num,
                    $netmask,
                    );
            }
            else {
                return
                    unless $object->process_value_record(
                    $node_num,
                    $dir,
                    $value,
                    $self->{_data_index}{$value},
                    $ip_num,
                    $netmask,
                    );
            }
        }
    };

    return $iterator;
}

# XXX - this method is only used for testing, but it's useful to have
sub lookup_ip_address {
    my $self    = shift;
    my $address = shift;

    require MaxMind::IPDB::Writer::Tree::Processor::LookupIPAddress;

    my $processor = MaxMind::IPDB::Writer::Tree::Processor::LookupIPAddress->new(
        ip_address => $address );

    $self->iterate($processor);

    return $processor->value();
}

sub node_num_for_subnet {
    my $self   = shift;
    my $subnet = shift;

    my ( $node_num, $dir ) = $self->pointer_record_for_subnet($subnet);

    return $self->record_pointer_value(
        $self->get_record( $node_num, $dir ) );
}

sub pointer_record_for_subnet {
    my $self   = shift;
    my $subnet = shift;

    require MaxMind::IPDB::Writer::Tree::Processor::RecordForSubnet;

    my $processor
        = MaxMind::IPDB::Writer::Tree::Processor::RecordForSubnet->new(
        subnet => $subnet );

    $self->iterate($processor);

    return @{ $processor->record() };
}

sub node_count_under_node {
    my $self     = shift;
    my $node_num = shift;

    require MaxMind::IPDB::Writer::Tree::Processor::NodeCounter;

    my $processor
        = MaxMind::IPDB::Writer::Tree::Processor::NodeCounter->new();

    $self->iterate( $processor, $node_num );

    return $processor->node_count();
}

__PACKAGE__->meta()->make_immutable();

1;
