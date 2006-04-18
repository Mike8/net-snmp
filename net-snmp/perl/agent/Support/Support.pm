####################################################################
#
# SnmpAgent module for use with the code generated by mib2c with the 
# embedded perl configuration file mib2c.perl.conf
#
# Copyright Tripleplay Services Limited 2005
# All rights reserved.
#
# Use is subject to license terms specified in the COPYING file
# distributed with the Net-SNMP package.
#
####################################################################

package NetSNMP::agent::Support;
require Exporter;

use NetSNMP::OID (':all');
use NetSNMP::agent (':all');
use NetSNMP::ASN (':all');
use Data::Dumper;
use XML::Simple;
use IO::File;


our @ISA       = qw(Exporter getLeaf);
our @EXPORT    = qw(registerAgent getOidElement setOidElement);
our @EXPORT_OK = qw();
our $VERSION   = 1.00;

use strict;

BEGIN {
    print STDERR "Module SnmpAgent.pm loaded ok\n";
}

# set to 1 to get extra debugging information
my $debugging = 0;

# if we're not embedded, this will get auto-set below to 1
my $subagent = 0;

################################################################
# The oidtable is used for rapid random access to elements with known
# oids, such as when doing gets/sets. It is not so good for
# ordered access. For that we build a tree (see below) and setup 
# next links in the oidtable to aid in evaluating where to go next
# for GETNEXT requests.
################################################################
my $oidtable;
my $oidtree;

# oidroot holds the top most oid record in the table. 
my $oidroot = "";

################################################################
# Build a tree for handling getnext requests
# Some parts borrowed from the perl cookbook
################################################################
sub buildTree {
    foreach my $key (keys %$oidtable) {
	insert($oidtree, $key);
    }
}

sub printTree {
    my ($tree) = @_;
    return unless $tree;
    printTree($tree->{LEFT});
    print $tree->{VALUE}. "\n";
    printTree($tree->{RIGHT});
}

my $prev="";
##############################################################
# Walk the sorted oid tree and set the 'next' links in the 
# oidtable.
##############################################################
sub doLinks {
    my ($tree) = @_;
    return unless $tree;
    doLinks($tree->{LEFT});
    if($oidroot eq "") {
	$oidroot = $tree->{VALUE};
#	print "Setting oidroot to $oidroot\n";
    }
    if($prev ne "") {
	$oidtable->{$prev}->{next} = $tree->{VALUE};
    }
    $prev = $tree->{VALUE};
    my $node = $oidtable->{$tree->{VALUE}};
    doLinks($tree->{RIGHT});
}

################################################################
# Insert a node into the tree
################################################################
sub insert {
    my ($tree, $value) = @_;
    unless ($tree) {
	$tree = {};  # Allocate memory
	$tree->{VALUE} = $value;
	$tree->{LEFT} = undef;
	$tree->{RIGHT} = undef;
	$_[0] = $tree;
	return ;
    }
    my $tv = new NetSNMP::OID($tree->{VALUE});
    my $mv = new NetSNMP::OID($value);
    if ($tv > $mv) {
	insert($tree->{LEFT}, $value);
    } elsif ($tv < $mv) {
	insert($tree->{RIGHT}, $value);
    } else {
	print "ERR: Duplicate insert of $value\n";
    }
}

#################################################################
## Main interface. 
## registerAgent(oid);
#################################################################
sub registerAgent {
    my $agent = shift;
    my $regat = shift;
    $oidtable = shift;

    print STDERR "Building OID tree\n";
    buildTree();

    doLinks($oidtree);

#    print Dumper($oidtable);

    # Debug. Print the list of oids in their next ordering
    my $node = $oidroot;
    while($node) {
#	print $node . "\n";
	$node = $oidtable->{$node}->{next};
    }

# where we are going to hook onto
    my $regoid = new NetSNMP::OID($regat);
    print "registering at ",$regoid,"\n" if ($debugging);
    
# If we're not running embedded within the agent, then try to start
# our own subagent instead.
    if (! $agent) {
	$agent = new NetSNMP::agent('Name' => 'test', # reads test.conf
			    'AgentX' => 1);   # make us a subagent
	$subagent = 1;
	print STDERR "started us as a subagent ($agent)\n"
	}
    
# we register ourselves with the master agent we're embedded in.  The
# global $agent variable is how we do this:
    print Dumper($agent) if ($debugging);
    $agent->register('myname',$regoid, \&my_snmp_handler);
}
 
   
######################################################################
# The subroutine to handle the incoming requests to our
# part of the OID tree.  This subroutine will get called for all
# requests within the OID space under the registration oid made above.
######################################################################
sub my_snmp_handler {
    my ($handler, $registration_info, $request_info, $requests) = @_;

    my $request;
    my $reqnum=1;

#    print STDERR "refs: ",join(", ", ref($handler), ref($registration_info), 
	#		       ref($request_info), ref($requests)),"\n";

    print "==============================================\n" if ($debugging);

    print STDERR "processing a request of type " . 
	$request_info->getMode() . "\n" if ($debugging) ;
    #
    # Process each varbind in teh list of requests
    #
    for($request = $requests; $request; $request = $request->next()) {
      my $oid = $request->getOID();
      print STDERR "--  processing request of $oid (request $reqnum) \n"  if ($debugging);

      #
      # Handle the different request types
      #
      my $mode = $request_info->getMode();
      if ($mode == MODE_GET) {
	  getLeaf($oid, $request, $request_info);
      } elsif ($mode == MODE_GETNEXT) {
	  getNextOid($oid, $request, $request_info);
      } else {
	  print STDERR "Request type $mode not supported\n";
      }

      $reqnum++;
    }

    print STDERR "  finished processing\n"
	if ($debugging);
}

##########################################################
# Given an oid see if there is an entry in the oidtable
# and get the record if there is.
#
# Passed the oid as a NetSNMP oid
#
# Returns the record if found
#
##########################################################
sub findOid {
    my $oid = shift;

    # Convert the OID to a string
    # The index items are temporarily set to zero to cater for tables
    my @indexes = $oid->to_array();

    my $idxoffset = $oid->length() - 1;

    # Locate the record in the table if it exists
    # If no match then try setting index values to zero until
    # we have a match of we exhaust the oid
    while($idxoffset) {
	my $oidstr="." . join ".", @indexes;
	my $rec = $oidtable->{$oidstr};

	# Return the record if found and the repaired index array
	if($rec) {
	    print "Found OID $oid ($oidstr) in the table\n"  if ($debugging);
	    return ($rec);
	} else {
	    # Not found. Set the next potential index to zero and
	    # try again
	    $indexes[$idxoffset] = 0;
	    $idxoffset--;
	}
    }
    return (0);
}


##########################################################
# Sub to return an element of an OID
# This is commonly used to get an index item from 
# an OID for table accesses.
##########################################################
sub getOidElement {
    my ($oid, $idx) = @_;

    my @idx = $oid->to_array();
    my $len = $oid->length();
    my $val = $idx[$idx];
    return $val;
}
##########################################################
# Sub to set an element of an OID
# Returns a new NetSNMP::OID object
##########################################################
sub setOidElement {
    my ($oid, $offset, $val) = @_;

    my @idx = $oid->to_array();
    $idx[$offset] = $val;
    my $str = "." . join ".", @idx;
    return new NetSNMP::OID($str);;
}


##########################################################
# Given scalar record in the oidtable get the value.
# Passed the record and the request.
##########################################################
sub getScalar {
    my ($rec, $request) = @_;

    # Got a scalar node from the table
    my $type = $rec->{type};
    
    # Call the GET function
    my $val = $rec->{func}();
    
    $request->setValue($type, $val);
}

############################################################
# Given a record in the OID table that is a columnar object
# locate any objects that have the required index.
#
# Passed the record, the oid object and the request
############################################################
sub getColumnar {
    my ($rec, $oid, $request) = @_;

    print "Get Columnar $oid\n"   if ($debugging);

    my $type = $rec->{type};
    my $args = $rec->{args};
    
    # Check the index is in range and exists
    if($rec->{check}($oid)) {
	
	# Call the handler function with the oid
	my $val = $rec->{func}($oid);

	# Set the value found in the request
	$request->setValue($type, $val);
    }
}

######################################################################
#
# If the oid is in range then set the data in the supplied request
# object.
# 
# Tries to get a scalar first then checks the coumnar second
#
# Return 1 if successful or 0 if not
#
#######################################################################
sub getLeaf {
    my $oid          = shift;
    my $request      = shift;
    my $request_info = shift;

    print "getLeaf: $oid\n"  if ($debugging);

    # Find an oid entry in the table
    my ($rec) = findOid($oid);
    if($rec) {

	# Record found. Use the istable flag to pass control to the
	# scalar or coulmnar handler
	if($rec->{istable} == 1) {
	    return getColumnar($rec, $oid, $request);
	} else {
	    return getScalar($rec, $request);
	}
    }
}

#####################################################
#
# getNextOid
#
# The workhorse for GETNEXT.
# Given an OID, locates the next oid and if valid does
# a getLeaf on that OID. It does this by walking the list of
# OIDs. We try to otimise the walk by first looking for an oid
# in the list as follows:
#
# 1. Try to locate an oid match in the table.
#    If that succeeds then look for the next object in the table 
#    using the next attribute and get that object.
#
# 2. If the OID found is a table element then use the table
#    specific index handler to see if there is an item with the
#    next index.This will retutn either an oid which we get, or 0.
#    If there is not then we continue our walk along the tree
#
#  3.If the supplied oid is not found, but is in the range of our  oids
#    then we start at the root oid and walk the list until we either 
#    drop of the end, or we fnd an OID that is greater than the OID supplied.
#    In all cases if we sucessfully find an OID to retrieve, 
#    then we set the next OID in the resposnse.
#
######################################################
sub getNextOid {
    my $oid          = shift;
    my $request      = shift;
    my $request_info = shift;

    my $curoid = new NetSNMP::OID($oidroot); # Current OID in the walk

    # Find the starting position if we can
    my $current = findOid($oid);
#    print Dumper($current);
    if($current) {
	# Found the start in the table
	$curoid = new NetSNMP::OID($oid);
	
        # If the node we found is not a table then start at the
	# next oid in the table
	unless($current->{istable}) {

	    my $nextoid = $current->{next};
	    $curoid = new NetSNMP::OID($nextoid);
#	    print "Not a table so using the next $nextoid\n";
	    $current = $oidtable->{$nextoid};
	}
    }

    # If we cannot find the starting point in the table, then start
    # at the top and 
    # walk along the list until we drop off the end
    # or we get to an oid that is >= to the one we want.
    else {

#	print "Not found so using the top ($oidroot)\n";
	$current = $oidtable->{$oidroot};
	
	while($current && $curoid <= $oid) {
	    my $nextoid = $current->{next};
	    print "Trying $nextoid\n"   if ($debugging);
	    $current = $oidtable->{$nextoid};
	    $curoid = new NetSNMP::OID($nextoid);
	}
    }

    ##
    ## Got a starting point
    ## $current points to the node in the table
    ## $curoid is a NetSNMP::OID object with the oid we are trying
    ##
    print "Got a startng point of " . Dumper($current)   if ($debugging);
    while($current) {
	if($current->{istable}) {
	    
	    # Got a table oid. See if the next is valid for the table
#	    print "Trying table\n";

	    my $nextoid = $current->{nextoid}($curoid);

#	    print Dumper($nextoid);
	    if($nextoid) {
		getColumnar($current, $nextoid, $request);
		$request->setOID($nextoid);
		return;
	    }
	    
	    # No not this one so try the next
	    $nextoid = $current->{next};
	    $current = $oidtable->{$nextoid};
	    $curoid = new NetSNMP::OID($nextoid);
	    print "Trying next $curoid $nextoid\n"   if ($debugging);
	} else {

	    # Must be the current node
	    if(getScalar($current, $request)) {
		$request->setOID($curoid);
		return 1;
	    }	
	}
    }
}


# Return true from this module
1;
