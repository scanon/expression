use Data::Dumper;
use DBI;
use LWP::UserAgent;
use HTTP::Request::Common;
use Getopt::Long;
use strict;

my $db_name = undef;
my $db_user = undef;
my $db_pwd = undef;

my $usage = "This command requires a db_user and db_pwd for inserting the ontologies.  Both need to be in single quotes.  Example : perl ontology_populator_for_db1.pl -db_user='YourUserName' -db_pwd='YourDBPwd' \n";
(GetOptions('db_name=s' => \$db_name,
            'db_user=s' => \$db_user,
	    'db_pwd=s' => \$db_pwd)
     && @ARGV == 0) || die $usage;
die $usage if ((!defined $db_user) || (!defined $db_pwd) || (!defined $db_name));

my %ontology_databases = (
			  "Plant Ontology" => "http://palea.cgrb.oregonstate.edu/viewsvn/Poc/trunk/ontology/OBO_format/plant_ontology.obo",
			  "Plant Environmental Ontology" => "http://palea.cgrb.oregonstate.edu/viewsvn/Poc/trunk/ontology/collaborators_ontology/plant_environment/environment_ontology.obo",
			  "Microbial Environmental Ontology" => "http://www.berkeleybop.org/ontologies/envo/subsets/envo-basic.obo");
#OLD ENVO site  "http://envo.googlecode.com/svn/trunk/src/envo/envo-basic.obo");

my $full_db_name = 'DBI:mysql:'.$db_name;
my $dbh = DBI->connect($full_db_name,$db_user, $db_pwd, { RaiseError => 1, ShowErrorStatement => 1 } ); 
#my $dbh = DBI->connect('DBI:mysql:expression:db1.chicago.kbase.us',$db_user, $db_pwd, { RaiseError => 1, ShowErrorStatement => 1 } ); 

my $does_ontology_exist_q = qq^select id from Ontology where id = ? ^;
my $does_ontology_exist_qh = $dbh->prepare($does_ontology_exist_q) or die "Unable to prepare does_ontology_exist_q : $does_ontology_exist_q : " . $dbh->errstr();
my $insert_ontology_q = qq^insert into Ontology (id,name,definition,ontologySource) values(?,?,?,?)^;
my $insert_ontology_qh = $dbh->prepare($insert_ontology_q) or die "Unable to prepare insert_ontology_q : $insert_ontology_q : " . $dbh->errstr(); 

my $bad_count = 0;
my $already_in_the_db_count = 0;
my $inserted_count = 0;
foreach my $ontology_source (keys(%ontology_databases))
{
    my $ua = LWP::UserAgent->new();
    my $server_url = $ontology_databases{$ontology_source};

    my $resp = $ua->get($server_url);
    if (!$resp->is_success)
    {
	 die "Request failed: " . $resp->status_line . "\n" . $resp->content;
    }

    my @ontology_terms = split(/\[Term\]/, $resp->content);
    shift(@ontology_terms);

    print "\n\nNEW FILE $ontology_source\n\n";
    foreach my $term (@ontology_terms)
    {
	my @term_lines = split(/\n/,$term);
#print "TERM : \n".$term."\n";
	my $id = undef;
	my $name = undef;
	my $def = undef;
 	foreach my $term_line (@term_lines)
	{
	    if ($term_line =~ /^id:/)
	    {
		$id = substr($term_line, 4);
	    }
	    if ($term_line =~ /^name:/)
	    {
		$name = substr($term_line, 6);
	    }
	    if ($term_line =~ /^def:/)
	    {
		$term_line =~ m{\"(.*?)\"};
		$def = $1;
	    }
	    if ($term_line =~ /^\[Typedef\]/)
	    {
		last;
	    }
	}
	unless (defined($def))
	{
	    $def = '';
	}
	unless (defined($id) && defined($name) && defined($def))
	{
	    #print $term . "\n\n";
	    $bad_count++;
	    next; #should never happen but 
	}
        #CHECK IF IN THE db ALREADY
	$does_ontology_exist_qh->execute($id) or die "Unable to executee does_ontology_exist_q $id : $does_ontology_exist_q : " . $does_ontology_exist_qh->errstr(); 
	my $exist_check = undef;
	($exist_check) = $does_ontology_exist_qh->fetchrow_array();
	if (defined($exist_check))
	{
	    $already_in_the_db_count++;
	}
	#IF NOT IN DB DO THE INSERT
	else
	{
	    $insert_ontology_qh->execute($id,$name,$def,$ontology_source) or die "Unable to execute insert_ontology_q : $insert_ontology_q : " . $insert_ontology_qh->errstr(); 
	    $inserted_count++;
	}
#	print "ID: ". $id ."\n";
#	print "NAME: ". $name ."\n";
#	print "DEF: ". $def ."\n\n";
    }
    print $ontology_source . " RUNNING BAD COUNT $bad_count \n";
    print $ontology_source . " RUNNING ALREADY IN DATABASE COUNT $already_in_the_db_count \n";
    print $ontology_source . " RUNNING INSERTED COUNT $inserted_count \n";
}

exit(); 

