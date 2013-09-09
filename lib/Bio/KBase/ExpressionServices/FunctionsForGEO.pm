package Bio::KBase::ExpressionServices::FunctionsForGEO;
use strict;
use Statistics::Descriptive;
#use Bio::KBase::Exceptions;
# Use Semantic Versioning (2.0.0-rc.1)
# http://semver.org 
our $VERSION = "0.1.0";

=head1 NAME

ExpressionServices

=head1 DESCRIPTION



=cut

#BEGIN_HEADER
use DBI;
use Storable qw(dclone);
use Config::Simple;
use Data::Dumper; 
use IO::Uncompress::Gunzip qw(gunzip $GunzipError) ;
use IO::File; 
use LWP::Simple; 
use Bio::DB::Taxonomy;
use Bio::KBase;
use Bio::KBase::CDMI::CDMIClient; 
use JSON::RPC::Client; 

#require Exporter;

our (@ISA,@EXPORT);
@ISA = qw(Exporter);
@EXPORT = qw(new get_GEO_GSE_data);

 
sub new
{
    my($class, @args) = @_;
    my $self = {
    };
    bless $self, $class;
    #BEGIN_CONSTRUCTOR
    #Copied from M. Sneddon's TreeImpl.pm from trees.git f63b672dc14f4600329424bc6b404b507e9c2503   
    my($deploy) = @args; 
    if (! $deploy) { 
        # if not, then go to the config file defined by the deployment and import                                                      
        # the deployment settings   
	my %params; 
        if (my $e = $ENV{KB_DEPLOYMENT_CONFIG}) { 
            my $EXPRESSION_SERVICE_NAME = $ENV{KB_SERVICE_NAME}; 
            my $c = Config::Simple->new(); 
            $c->read($e); 
	    my %temp_hash = $c->vars();
            my @param_list = qw(dbName dbUser dbhost); 
            for my $p (@param_list) 
            { 
                my $v = $c->param("$EXPRESSION_SERVICE_NAME.$p"); 
                if ($v) 
                { 
                    $params{$p} = $v; 
                    $self->{$p} = $v; 
                } 
            } 
        } 
        else 
        { 
            $self->{dbName} = 'expression'; 
            $self->{dbUser} = 'expressionselect'; 
            $self->{dbhost} = 'db1.chicago.kbase.us'; 
        } 
        #Create a connection to the EXPRESSION (and print a logging debug mssg)              
	if( 0 < scalar keys(%params) ) { 
            warn "Connection to Expression Service established with the following non-default parameters:\n"; 
            foreach my $key (sort keys %params) { warn "   $key => $params{$key} \n"; } 
        } else { warn "Connection to Expression established with all default parameters.\n"; } 
    } 
    else 
    { 
         $self->{dbName} = 'expression'; 
         $self->{dbUser} = 'expressionselect';
         $self->{dbhost} = 'db1.chicago.kbase.us'; 
    } 
    #END_CONSTRUCTOR

    if ($self->can('_init_instance'))
    {
	$self->_init_instance();
    }
    return $self;
}


sub trim($)
{
    #removes beginning and trailing white space
    my $string = shift;
    if (defined($string))
    {
	$string =~ s/^\s+//;
	$string =~ s/\s+$//;
    }
    return $string;
}

sub column_header_checker
{
    my $col_name = shift;
    my $reg_ex = shift; 
    my $column_exists_flag = shift; 
    my $counter = shift; 
    if ($col_name =~ m/$reg_ex/i)
    { 
        if (defined($column_exists_flag))
        { 
            return "duplicate"; 
        } 
        else 
        { 
            return $counter;
        } 
    } 
    else 
    { 
        return $column_exists_flag; 
    } 
}

sub parse_gse_series_portion
{
    my $lines_array_ref = shift;
    my $gse_object = shift;
    my @lines = @{$lines_array_ref};

    my $gseID = undef;
    my $gseTitle = undef;
    my $gseSummary = undef;
    my $gseDesign = undef;
    my $gseSubmissionDate = undef;
    my $gsePubMedID = undef;
    my @gseErrors = ();
    my @gseWarnings = ();
    my %listed_gsm_hash;

    foreach my $line (@lines)
    {
	if ($line =~ m/\!Series_sample_id = /)
	{
	    my @temp_arr = split(/\s*=\s*/,$line);
	    $listed_gsm_hash{trim($temp_arr[1])} = 0;
	}
	if ($line =~ m/^\^SERIES = /)
	{
	    my @temp_arr = split(/\s*=\s*/,$line);
	    $gseID = trim($temp_arr[1]);
	}
        if ($line =~ m/^\!Series_title =/)
        {
            my @temp_arr = split(/\s*=\s*/,$line); 
            $gseTitle = trim($temp_arr[1]);
        }
	if ($line =~ m/^\!Series_summary = /) 
	{ 
	    my @temp_arr = split(/\s*=\s*/,$line);
	    if (defined($gseSummary))
	    {
		$gseSummary .= " :: " . trim($temp_arr[1]);
	    }
	    else
	    {
		$gseSummary = trim($temp_arr[1]);
	    }
	}
        if ($line =~ m/^\!Series_overall_design = /) 
        { 
            my @temp_arr = split(/\s*=\s*/,$line); 
            $gseDesign = trim($temp_arr[1]);
        } 
        if ($line =~ m/^\!Series_submission_date = /) 
        { 
            my @temp_arr = split(/\s*=\s*/,$line); 
            $gseSubmissionDate = trim($temp_arr[1]);
        } 
	if ($line =~ m/^\!Series_pubmed_id = /)
	{
	    my @temp_arr = split(/\s*=\s*/,$line);
	    $gsePubMedID = trim($temp_arr[1]);
	}
    }
    if (!(defined($gseID)))
    {
	push(@gseErrors,"No GEO Series ID found");
    }
    $gse_object={"gseID" => $gseID,
		  "gseTitle" => $gseTitle,
		  "gseSummary" => $gseSummary,
		  "gseDesign" => $gseDesign,
		  "gseSubmissionDate" => $gseSubmissionDate,
		  "gsePubMedID" => $gsePubMedID,
		  "gseErrors" => \@gseErrors,
		  "gseWarnings" => \@gseWarnings};
    return ($gse_object,\%listed_gsm_hash);
}


sub parse_gse_platform_portion
{ 
    my $platform_hash_ref = shift;
    my %platform_hash = %{$platform_hash_ref};
    my $metaDataOnly = shift;
    my $lines_array_ref = shift; 
    my @lines = @{$lines_array_ref};
    my $gsm_info_hash_ref = shift;
    my %gsm_platform_info_hash = %{$gsm_info_hash_ref};  #Hash that has GSMID as key (or "ALL_GSMS" as single key) -> {"organism"=>value,
                                #                                                             "taxID"=>value,
                                #                                                             "platform"=>GPLID}
                                #  NOTE THIS GETS VERY COMPLICATED IF NOT METADATA ONLY.  Remember multiple GPLs can exist per GSE
    my $self = shift; 
    my %platform_tax_probe_feature_hash; #  Need to return a map for probe mapping for the GPL to use if this is not metadata only
                                #  key {gplID->{taxID->{genome_id->{platform id value->feature_id it maps to}}}} 

    my @temp_arr = split(/\s*=\s*/,$lines[0]);
    my $gplID = trim($temp_arr[1]);
    my $gplTitle = undef;
    my $gplTechnology = undef;
    my $gplTaxID = undef;
    my $gplManufacturer = undef;
    my $gplOrganism = undef;

    $platform_hash{$gplID}->{"warnings"}=[];
    $platform_hash{$gplID}->{"errors"}=[];
    my $platform_table_begin = undef;
    my $platform_line_counter = 0;

    my $min_number_of_probes_mapped_threshold = .5;

    foreach my $line (@lines)
    {
	if ($line =~ m/^\!Platform_title =/) 
	{ 
	    my @temp_arr = split(/\s*=\s*/,$line); 
	    $gplTitle = trim($temp_arr[1]); 
	} 
        if ($line =~ m/^\!Platform_technology =/) 
        { 
            my @temp_arr = split(/\s*=\s*/,$line); 
            $gplTechnology = trim($temp_arr[1]);
        } 
        if ($line =~ m/^\!Platform_taxid =/)
        {
            my @temp_arr = split(/\s*=\s*/,$line);
            $gplTaxID = trim($temp_arr[1]);
        }
        if ($line =~ m/^\!Platform_manufacturer =/)
        {
            my @temp_arr = split(/\s*=\s*/,$line);
            $gplManufacturer = trim($temp_arr[1]);
        }
        if ($line =~ m/^\!Platform_organism =/)
        { 
            my @temp_arr = split(/\s*=\s*/,$line);
            $gplOrganism = trim($temp_arr[1]);
        } 
	if ($line =~ m/^\!platform_table_begin/)
	{
	    $platform_table_begin = $platform_line_counter + 1;
	    last;
	}
	$platform_line_counter++;
    }
    unless(defined($gplTitle))
    {
	push(@{$platform_hash{$gplID}->{"warnings"}},"The platform has no title");
    }
    $platform_hash{$gplID}->{"gplTitle"}=$gplTitle;

    unless(defined($gplTaxID))
    {
	push(@{$platform_hash{$gplID}->{"warnings"}},"The platform has no taxID");
    } 
    $platform_hash{$gplID}->{"gplTaxID"}=$gplTaxID;

    unless(defined($gplOrganism)) 
    { 
        push(@{$platform_hash{$gplID}->{"warnings"}},"The platform has no listed organism");
    } 
    $platform_hash{$gplID}->{"gplOrganism"}=$gplOrganism;
    
    if(defined($gplTechnology))
    {
	if (defined($gplManufacturer))
	{
	    $gplTechnology .= " :: ". $gplManufacturer; 
	}
    }
    else
    {
	if (defined($gplManufacturer))
	{
	    $gplTechnology = "Unknown :: ". $gplManufacturer;
	} 
    }
    $platform_hash{$gplID}->{"gplTechnology"}=$gplTechnology;
    if ($metaDataOnly == 0)
    {
	my %tax_ids_hash;  #a hash of tax ids for all the GSMs in a GSE for this GPL
	foreach my $temp_gsm_id (keys(%gsm_platform_info_hash))
	{
	    if ($gplID eq $gsm_platform_info_hash{$temp_gsm_id}->{"platform"})
	    {
		$tax_ids_hash{$gsm_platform_info_hash{$temp_gsm_id}->{"taxID"}} = 1;
	    }
	}

        #	push(@{$platform_hash{$gplID}->{"errors"}},"THIS CURRENTLY ONLY SUPPORTS METADATA ONLY!");
	my $dbh = DBI->connect('DBI:mysql:'.$self->{dbName}.':'.$self->{dbhost}, $self->{dbUser}, '',
			       { RaiseError => 1, ShowErrorStatement => 1 }
	    ); 
	my %genome_ids_hash;

	foreach my $temp_tax_id (keys(%tax_ids_hash))
	{
	    my $ncbi_db = Bio::DB::Taxonomy->new(-source=>"entrez");
	    #IF GSM uses current GPL
	    #Check for the GSMs Tax ID vs NCBI and get Scientific name.  Then look up genome by that scientific name.
	    my $ncbi_taxon = $ncbi_db->get_taxon(-taxonid=>$temp_tax_id);
	    my @ncbi_scientific_names = @{$ncbi_taxon->{'_names_hash'}->{'scientific'}};
	    my $get_genome_ids_q = "select id from kbase_sapling_v1.Genome where scientific_name in (".
		join(",", ("?") x @ncbi_scientific_names) . ") ";
	    my $get_genome_ids_qh = $dbh->prepare($get_genome_ids_q) or die "Unable to prepare get_genome_ids_q : $get_genome_ids_q ".
		$dbh->errstr();
	    $get_genome_ids_qh->execute(@ncbi_scientific_names) or die "Unable to execute get_genome_ids_q : $get_genome_ids_q " .
		$get_genome_ids_qh->errstr();
	    while (my ($genome_id) = $get_genome_ids_qh->fetchrow_array())
	    {
		$genome_ids_hash{$genome_id} = 1;
	    }
		
	    #determine if a sequence column exists 
	    my @platform_map_lines = @lines[$platform_table_begin..(scalar(@lines)-2)];
	    
	    my ($probe_sequence_hash_ref, $probe_sequence_warning) = make_platform_sequence_hash(\@platform_map_lines);
	    my %probe_sequence_hash = %{$probe_sequence_hash_ref};
	    my @blat_files_to_clean_up_after;
	    my %genome_probe_to_feature_id_hash;  #key genome_id -> {probe_id => feature_id}

	    if (!defined($probe_sequence_warning))
	    {
		#It has a sequence column, prepare a blat_db file and build query file
		my $min_probe_length = 500;  #artificially high intial value will get set
		my $number_of_probe_sequences = scalar(keys(%probe_sequence_hash));
		my $blat_platform_query_file = "/kb/dev_container/modules/expression/blat_files/".$gplID."_blat_query_file";
		push(@blat_files_to_clean_up_after, $blat_platform_query_file);
		open (BLAT_QUERY_FILE, ">".$blat_platform_query_file) or die "Unable to make $blat_platform_query_file \n";
		foreach my $probe_id (keys(%probe_sequence_hash))
		{
		    my $probe_sequence = $probe_sequence_hash{$probe_id};
		    print BLAT_QUERY_FILE ">".$probe_id."\n".$probe_sequence."\n";
		    if (length($probe_sequence) < $min_probe_length)
		    {
			$min_probe_length = length($probe_sequence);
		    }
		}
		$min_probe_length = $min_probe_length - 1; #allows for 1 base mismatch in blat
		close (BLAT_QUERY_FILE);
		#FOREACH MATCHING GENOME
		#Create DB file of CDS
		#Run blat
		#create mapping platform_id -> feature_id
		#remove files
		foreach my $genome_id (keys(%genome_ids_hash))
		{
		    #create Blat DB File
		    my $file_genome_id = $genome_id;
		    $file_genome_id =~ s/kb\|//; 
		    my $blat_genome_db_file = "/kb/dev_container/modules/expression/blat_files/".$file_genome_id."_blat_db_file";
		    push(@blat_files_to_clean_up_after, $blat_genome_db_file);
		    open (BLAT_DB_FILE, ">".$blat_genome_db_file) or die "Unable to make $blat_genome_db_file \n";
		    my $fid_count = 0;
		    my $kb = Bio::KBase->new();
		    my $cdmi_client = $kb->central_store;
		    my $genome_fids_hash_ref = $cdmi_client->genomes_to_fids([$genome_id],['CDS']);
		    my $fid_sequence_hash = $cdmi_client->fids_to_dna_sequences($genome_fids_hash_ref->{$genome_id}); 
		    foreach my $fid_key (keys(%{$fid_sequence_hash})) 
		    { 
			$fid_count++;
			print BLAT_DB_FILE ">".$fid_key."\n".$fid_sequence_hash->{$fid_key}."\n"; 
		    } 
		    close(BLAT_DB_FILE); 
		    # Run Blat
		    my $blat_results_file = "/kb/dev_container/modules/expression/blat_files/".
			$gplID."_".$file_genome_id."_blat_results.psl";
		    my $cmd = "/usr/local/bin/blat -t=dna -q=dna -tileSize=6 -repMatch=1000000 -minIdentity=95 -fine ".
			"-minMatch=0 -out=psl -minScore=$min_probe_length ".
			"$blat_genome_db_file $blat_platform_query_file $blat_results_file"; #-intron=0
                    #print "Running blat: $cmd\n"; 
		    system($cmd) == 0 || die "Cannot run blat"; 
		    die "blat failed" unless -e $blat_results_file; 
		    push(@blat_files_to_clean_up_after, $blat_results_file);
		    #Parse Blat File and create mapping from Platform ID to Feature ID
		    my %probe_to_feature_hash =  parse_blat_results($blat_results_file);  
		    $platform_tax_probe_feature_hash{$gplID}->{$temp_tax_id}->{$genome_id} = \%probe_to_feature_hash; 
		    #if number of probe sequences mapped to feature ids is less than (.5 * total number of probe sequences)
		    #add a warning.
		    if (scalar(keys(%probe_to_feature_hash)) < 
			($min_number_of_probes_mapped_threshold * $number_of_probe_sequences))
		    {
			push(@{$platform_hash{$gplID}->{"warnings"}},"For $gplID , for genome $genome_id only ".
			     scalar(keys(%probe_to_feature_hash)). 
			     " number of probes were able to be mapped to features out of the ".
			     $number_of_probe_sequences . " total number of probes.");
		    }
		    $platform_hash{$gplID}->{"mapping_method"}="Probe Sequences Blat Resolved";
		    #MAY want to add self so can connect to DB to resolve alternative splicings
		}
		foreach my $clean_up_file (@blat_files_to_clean_up_after) 
		{ 
		    my $rm_cmd = "rm ".$clean_up_file; 
		    system($rm_cmd) == 0 || print "Cannot perform $rm_cmd \n"; 
		} 
	    }
	    else
	    {
		#no sequence column exists, see if a locus tag/aliases column exists
		#create mapping platform_id -> feature_id
		my $genome_synonyms_lookup_ref;  #key Genome ID ->{synonym->{featureIDS->[external Synonym DB IDs]}
		#                 'feature_coverage_percentage'->number} 
		($genome_synonyms_lookup_ref) = create_genome_synonyms_lookup(\%genome_ids_hash);
		#%genome_probe_to_feature_id_hash;  #key genome_id -> {probe_id => feature_id}  
		my ($temp_hash_ref,$warnings_arr_ref, $errors_arr_ref) = parse_platform_synonyms(\@platform_map_lines,$genome_synonyms_lookup_ref);
		%genome_probe_to_feature_id_hash = %{$temp_hash_ref};
		my $passed_synonyms_mapping = 0;
		my %represented_genome_ids;  #keep track of genomes that passed.  May have errors with other genomes to report warnings on.
		foreach my $test_genome_id (keys(%genome_probe_to_feature_id_hash))
		{
		    my %probe_to_feature_hash = %{$genome_probe_to_feature_id_hash{$test_genome_id}};
		    if (scalar(keys(%probe_to_feature_hash)) > 1)
		    {
			$passed_synonyms_mapping = 1;
		    }
		    #if number of probe sequences mapped to feature ids is less than (.5 * total number of probe sequences) 
		    #add a warning.   
		    if (scalar(keys(%probe_to_feature_hash)) <
			($min_number_of_probes_mapped_threshold * (scalar(@platform_map_lines) - 1))) 
		    { 
			push(@{$platform_hash{$gplID}->{"warnings"}},"For $gplID , for genome $test_genome_id only ".
			     scalar(keys(%probe_to_feature_hash)). 
			     " number of probes were able to be mapped to features out of the ". 
			     (scalar(@platform_map_lines) - 1) . " total number of platform lines."); 
		    } 
		    foreach my $temp_warning (@{$warnings_arr_ref})
		    {
			if ($temp_warning =~ m/ $test_genome_id /) {
			    push(@{$platform_hash{$gplID}->{"warnings"}},"Warning for Platform $gplID and genome $test_genome_id : ".
				 $temp_warning);
			} 
		    }
		    $represented_genome_ids{$test_genome_id}=1;
		}

		foreach my $genome_id (keys(%genome_ids_hash)) 
		{ 
		    unless(defined($represented_genome_ids{$genome_id})) #Error with other genomes captured for reporting purposes
		    {
			foreach my $temp_error (@{$errors_arr_ref}) 
			{
			    if ($temp_error =~ /\Q$genome_id \E/) 
			    { 
				push(@{$platform_hash{$gplID}->{"warnings"}},"ERROR for Platform $gplID and genome $genome_id : ". 
				     $temp_error);
			    }
			} 
		    }
		}
		if ($passed_synonyms_mapping == 1) 
		{
		    $platform_hash{$gplID}->{"mapping_method"}="Platform External IDs Translation";
		    $platform_tax_probe_feature_hash{$gplID}->{$temp_tax_id} = \%genome_probe_to_feature_id_hash; 
		}
		else
		{
		    $platform_hash{$gplID}->{"mapping_method"}="UNABLE TO MAP PROBES BY SEQUENCE OR EXTERNAL IDS";
		    push(@{$platform_hash{$gplID}->{"errors"}},"UNABLE TO MAP PROBES BY SEQUENCE OR EXTERNAL IDS");        
		}
	    }
	}
    }
    #ADD ALL SORTS OF MAPPING (by sequence or gene aliases) OF PROBES TO FEATURES LOGIC IN HERE
    #PLATFORM TABLE is located in @lines[$platform_table_start..(scalar(@lines))]
    #Will populate the     $platform_hash{$gplID}->{"id_to_feature_mappings"}={id from Platform section mapped to the feature_id};
    #Will populate the     $platform_hash{$gplID}->{"mapping_approach"}=text "sequence" or "alias";
    $platform_hash{$gplID}->{"processed"}=1; 
    #print "\nPLATFORM_TAX_PROBE_FEATURE_HASH : ". Dumper(\%platform_tax_probe_feature_hash);
    return (\%platform_hash,\%platform_tax_probe_feature_hash);
}   #END OF parse_gse_platform_portion

sub parse_platform_synonyms
{
    my $lines_array_ref = shift; 
    my @lines = @{$lines_array_ref}; 
    
    my $genomes_synonyms_lookup_ref = shift;
    #print "\nDUMP OF parse_platform_synonyms : \n".Dumper($genomes_synonyms_lookup_ref);

    my %genomes_synonyms_lookup = %{$genomes_synonyms_lookup_ref};
    
    my $rows_with_synonyms_threshold = .6;
    
    my %genome_probe_to_feature_id_hash;  #key genome_id -> {probe_id => feature_id}     
    my @header_columns = split(/\t/,shift(@lines)); 
    my $id_col_exists = undef; 
    my $header_counter = 0; 
    my @warnings;
    my @errors;
    
    my %column_single_synonym_count_hash; 
    my %column_multiple_synonym_count_hash; 

    foreach my $header_column (@header_columns) 
    { 
        $id_col_exists = column_header_checker(trim($header_column),'^id$',$id_col_exists,$header_counter); 
        $column_single_synonym_count_hash{$header_counter} = 0; 
        $column_multiple_synonym_count_hash{$header_counter} = 0; 
        $header_counter++; 
    } 
    if ($id_col_exists eq 'duplicate') 
    { 
        push(@warnings,"There is more than one 'ID' column"); 
    } 
    elsif (!defined($id_col_exists)) 
    { 
        push(@warnings,"An 'ID' column was not found in this platform"); 
    } 
    else 
    { 
	foreach my $genome_id (keys(%genomes_synonyms_lookup))
	{
	    if (defined($genomes_synonyms_lookup{$genome_id}))
	    {
		my %synonyms_lookup = %{$genomes_synonyms_lookup{$genome_id}};
		my %column_single_synonym_count_hash;  #column index -> count of hits in synonym lookup with one feature only
		my %column_multiple_synonym_count_hash;#column index -> count of hits in synonym that only have multiple features mapped to it
		#determine which column has the most synonyms.
		foreach my $line (@lines) 
		{ 
		    my $element_counter = 0;
		    my @line_elements = split(/\t/,$line); 
		    foreach my $line_element (@line_elements)
		    {
			if (defined($synonyms_lookup{trim($line_element)}))
			{
			    my $num_feature_elements = scalar(keys(%{$synonyms_lookup{trim($line_element)}}));
			    if ($num_feature_elements == 1)
			    {
				$column_single_synonym_count_hash{$element_counter}++;
			    }
			    elsif ($num_feature_elements > 1)
			    {
				$column_multiple_synonym_count_hash{$element_counter}++;
			    }
			}
			$element_counter++;
		    }
		}
		#determine column that had the most singles and ensure singles mor prevalent then multiples
		my $max_amount = 0;
		my $max_col_index = undef;
		foreach my $col_index (keys(%column_single_synonym_count_hash))
		{
		    if ($column_single_synonym_count_hash{$col_index} > $max_amount)
		    {
			$max_col_index = $col_index;
			$max_amount = $column_single_synonym_count_hash{$col_index};
		    }
		}
		if (($max_amount / scalar(@lines)) < $rows_with_synonyms_threshold)
		{
		    push(@errors,"For Genome $genome_id only " .$max_amount." out of " . scalar(@lines) . 
			 " platform rows mapped to one feature by synonym lookup.");
		}
		else
		{
		    if (($column_multiple_synonym_count_hash{$max_col_index}/$max_amount) > .10)
		    {
			push(@warnings,"For Genome $genome_id more than 10 percent of ids map to multiple feature ids.  ".
			     "Trying best to intellegently resolve them."); 
		    }
		    else
		    {
			#NOW have column with most synonyms
			#go through that column and count the external DB hits.  
			#(the one with most will be used to resolve multiple features to a synonym
			my %external_db_hash_count;  #Hash to keep track of what external db is the most prevalent 
			     #(used to resolve multiple feature ids mapping to one synonym)
			foreach my $line (@lines)
			{
			    my @line_elements = split(/\t/,$line); 
			    if (defined($synonyms_lookup{trim($line_elements[$max_col_index])}))
			    {
				my %feature_id_hash = %{$synonyms_lookup{trim($line_elements[$max_col_index])}};
				foreach my $feature_id (keys(%feature_id_hash))
				{
				    my @external_dbs = @{$synonyms_lookup{trim($line_elements[$max_col_index])}->{$feature_id}};
				    foreach my $external_db (@external_dbs)
				    {
					if (defined($external_db_hash_count{$external_db}))
					{
					    $external_db_hash_count{$external_db}++;
					}
					else
					{
					$external_db_hash_count{$external_db} = 1;
					}
				    }
				}
			    }
			}
			my $max_external_db;
			my $max_external_db_count = 0;
			foreach my $external_db (keys(%external_db_hash_count))
			{
			    if ($external_db_hash_count{$external_db} > $max_external_db_count)
			    {
				$max_external_db = $external_db;
				$max_external_db_count = $external_db_hash_count{$external_db};
			    }
			}
			my $count_of_synonym_collisions_mapped_by_external_db = 0;
			foreach my $line (@lines)
			{
			    #map id_col to features
			    my @line_elements = split(/\t/,$line); 
			    if (defined($synonyms_lookup{trim($line_elements[$max_col_index])}))
                            { 
				my %feature_id_hash = %{$synonyms_lookup{trim($line_elements[$max_col_index])}}; 
				if (scalar(keys(%feature_id_hash)) == 1)
				{
				    my ($feature_id) = keys(%feature_id_hash);
				    $genome_probe_to_feature_id_hash{$genome_id}->{trim($line_elements[$id_col_exists])} = trim($feature_id);  
				    #key genome_id -> {probe_id => feature_id}     			    
				}
				elsif (scalar(keys(%feature_id_hash)) > 1)
				{
				    foreach my $feature_id (keys(%feature_id_hash)) 
				    { 
					my @external_dbs = @{$synonyms_lookup{trim($line_elements[$max_col_index])}->{$feature_id}}; 
					foreach my $external_db (@external_dbs) 
					{
					    if ($external_db == $max_external_db)
					    {
						$genome_probe_to_feature_id_hash{$genome_id}->{trim($line_elements[$id_col_exists])} = 
						    trim($feature_id);  
						$count_of_synonym_collisions_mapped_by_external_db++;
					    }
					}
				    }
				}
			    }
			}
			if ($count_of_synonym_collisions_mapped_by_external_db > 0)
			{
			    push(@warnings,"For Genome $genome_id there were ".
				 $count_of_synonym_collisions_mapped_by_external_db ." feature collisions for a synonym resolved by external id.");
			}
		    }
		}
	    }
	}
    }
    return (\%genome_probe_to_feature_id_hash,\@warnings,\@errors);
} #end parse_platform_synonyms


#Get Synonyms for the Genome
sub create_genome_synonyms_lookup
{
    my $genome_hash_ref = shift;
    my $client = new JSON::RPC::Client;
    my @genome_ids = keys(%{$genome_hash_ref});


    my %genome_synonyms_lookup;  #key Genome ID ->{synonym->{featureIDS->[external Synonym DB IDs]}                               
    #                 'feature_coverage_percentage'->number}     
    my $client = new JSON::RPC::Client; 
    my $base_url ="http://140.221.84.201/api/idmapping/kbaseID/?limit=100;format=json;identifier__in="; 	

    foreach my $genome_id (@genome_ids)
    {
	my $kb = Bio::KBase->new(); 
	my $cdmi_client = $kb->central_store; 
	my $genome_fids_hash_ref = $cdmi_client->genomes_to_fids([$genome_id],['CDS']); 
 
	my @feature_ids = @{$genome_fids_hash_ref->{$genome_id}}; 
	my %feature_id_coverage_hash;  #KEYS FEATURE_ID -> VALUE 1
 
	my %synonym_kbase_id_hash;  #key synonym -> {KBase Feature IDs=>[externalDBIDs]}                                              
	my $callobj = {}; 
 
	my $counter = 0; 
	my $feature_count = scalar(@feature_ids); 
	my $increment = 20;
	for(my $feature_counter=0;$feature_counter<$feature_count;$feature_counter = $feature_counter + $increment) 
	{ 
	    my $upward_limit = $feature_counter + ($increment - 1); 
	    if ($upward_limit > $feature_count) 
	    { 
		$upward_limit = $feature_count -1; 
	    } 
	    my @temp_feature_ids = @feature_ids[$feature_counter..$upward_limit]; 
	    my $temp_url = $base_url . join(';identifier__in=',@temp_feature_ids);
	    my $res = $client->call($temp_url, $callobj); 
	    if(defined($res->{'content'}->{'objects'}))
	    { 
		my @feature_objects = @{$res->{'content'}->{'objects'}};
		foreach my $feature_object (@feature_objects) 
		{ 
		    my $kbase_feature_id = $feature_object->{'identifier'};
		    if (defined($feature_object->{'externalids'})) 
		    { 
			$feature_id_coverage_hash{$kbase_feature_id}=1;
			my @external_id_objects = @{$feature_object->{'externalids'}}; 
			foreach my $external_id_object (@external_id_objects) 
			{ 
			    my $synonym = $external_id_object->{'identifier'}; 
			    my $synonym_db = $external_id_object->{'externaldb'}->{'id'}; 
			    push(@{$synonym_kbase_id_hash{$synonym}->{$kbase_feature_id}},$synonym_db); 
			} 
		    } 
		} 
	    } 
	}
	$synonym_kbase_id_hash{'feature_coverage_percentage'}=(scalar(keys(%feature_id_coverage_hash)) / scalar(@feature_ids)) * 100;
	$genome_synonyms_lookup{$genome_id}=\%synonym_kbase_id_hash;	
    }
    return \%genome_synonyms_lookup;
}



#parses blat results_file
sub parse_blat_results
{
    my $blat_results_file = shift;
    open (BLAT,$blat_results_file) or die "Unable to open the blat file : $blat_results_file.\n\n";
    my @blat_lines = (<BLAT>);
    close(BLAT);
    chomp(@blat_lines);
    
    my $past_header = 0;
    while ($past_header == 0)
    {
	my $temp_line = shift(@blat_lines);
	if ($temp_line =~ /^---------------------------------------------------------------------------------------------------------------------------------------------------------------$/)
	{
	    $past_header = 1;
	}
    }
    #Assumes psLayout version 3 (headers, odd 2 row headers) :
    #match   mis-    rep.    N's     Q gap   Q gap   T gap   T gap   strand  Q               Q       Q       Q       T               T       T       T       block   blockSizes      qStarts  tStarts 
    #        match   match           count   bases   count   bases           name            size    start   end     name            size    start   end     count 

    #populate potential candidates if pass (max is 1 mismatch across the length of the probe)
    my %potential_candidates;  #key q_name value = [of lines]
    #my $met_match_criteria = 0;
    foreach my $blat_line (@blat_lines)
    {
	my @blat_elements = split(/\t/,$blat_line);
	my $match = $blat_elements[0];
	my $mis_match = $blat_elements[1];
	my $q_name = $blat_elements[9];
	my $q_size = $blat_elements[10];
	my $t_name = $blat_elements[13];
	my $block_count = $blat_elements[17];
	#criteria at max 1 mismatch along entire length of the probe.  block count must equal 1.
	if (((($q_size - $match) + $mis_match) <= 1) && ($block_count == 1))
	{
	    #$met_match_criteria++;
	    if (!defined($potential_candidates{$q_name}))
	    {
		$potential_candidates{$q_name} = [];
		#push(@{$potential_candidates{$q_name}},$blat_line);
	    }
	    push(@{$potential_candidates{$q_name}},$blat_line);
	}
    }
    my %probe_feature_id_hash;

    foreach my $candidate_q_name (keys(%potential_candidates))
    {
	my @blat_lines = @{$potential_candidates{$candidate_q_name}};
	if (scalar(@blat_lines) == 1)
	{
	    my @blat_elements = split(/\t/,$blat_lines[0]);
	    my $t_name = $blat_elements[13];
	    $probe_feature_id_hash{$candidate_q_name} = $t_name;
	}
	else
	{
	    #compare the multiple hits.  Take the perfect hit if only one perfect hit exists.
	    #otherwise you have multiple perfect hits or multiple 1 mismatch hits.  Results are ambiguous.  
	    #Nothing gets put into the hash.
	    my $num_perfect_hits = 0;
	    my $perfect_t_name;
	    foreach my $blat_line (@blat_lines)
	    {
		my @blat_elements = split(/\t/,$blat_line);
		my $match = $blat_elements[0]; 
		my $mis_match = $blat_elements[1];
		my $q_size = $blat_elements[10];
		my $t_name = $blat_elements[13]; 
		my $block_count = $blat_elements[17]; 
		#criteria at max 1 mismatch along entire length of the probe.  block count must equal 1.
		if (((($q_size - $match) + $mis_match) == 0) && ($block_count == 1))
		{ 
		    $num_perfect_hits++;
		    $perfect_t_name = $t_name;
		}
	    }
	    if ($num_perfect_hits == 1)
	    {
		$probe_feature_id_hash{$candidate_q_name} = $perfect_t_name;
	    }
	}
    }
    return %probe_feature_id_hash;
}



sub make_platform_sequence_hash
{
    my $lines_array_ref = shift; 
    my @lines = @{$lines_array_ref}; 

    my @header_columns = split(/\t/,shift(@lines));
    my $id_col_exists = undef;
    my $header_counter = 0;
    my $warning = undef;
    my %sequence_hash_counter;  #Hash with column position (integer starting at zero) and number of values that are DNA
    my $percent_threshold = .75;
    my %probe_hash; #key = platform id, value = sequence.  This hash will be used to create the Blat query file.

    foreach my $header_column (@header_columns)
    {
	$id_col_exists = column_header_checker(trim($header_column),'^id$',$id_col_exists,$header_counter);
	$sequence_hash_counter{$header_counter} = 0;
	$header_counter++;
    }
    if ($id_col_exists eq 'duplicate')
    {
	$warning = "There is more than one 'ID' column";
    }
    elsif (!defined($id_col_exists))
    {
	$warning = "An 'ID' column was not found in this platform";
    }
    else
    {
	#determine which column has the most sequences.
	foreach my $line (@lines)
	{
	    my @line_elements = split(/\t/,$line);
	    for (my $i = 0; $i < scalar(@line_elements); $i++)
	    {
		if ((trim($line_elements[$i]) =~ m/^[ACGTacgt]*$/) && (length(trim($line_elements[$i])) >= 20)) 
		{ 
		    $sequence_hash_counter{$i} =  $sequence_hash_counter{$i} + 1;
		}
	    }
	}
	my $max_index = undef;
	my $max_value = 0;
	foreach my $col_index (keys(%sequence_hash_counter))
	{
	    if ($sequence_hash_counter{$col_index} > $max_value)
	    {
		$max_value = $sequence_hash_counter{$col_index};
		$max_index = $col_index;
	    }
	}
	if ($max_value < ($percent_threshold * scalar(@lines)))
	{
	    $warning = "A column did not exist in the platform that passed thresholds for being a sequence column";
	}
	else
	{
	    #create map of probe_hash
	    foreach my $line (@lines)
	    { 
		my @line_elements = split(/\t/,$line); 
                if ((trim($line_elements[$max_index]) =~ m/^[ACGTacgt]*$/) && (length(trim($line_elements[$max_index])) >= 20))
                { 
                    $probe_hash{trim($line_elements[$id_col_exists])} = trim($line_elements[$max_index]);
                }
	    }
	}
    }
    #print "NUMBER OF ELEMENTS IN PROBE HASH : ". scalar(keys(%probe_hash))."\n";
    #print "PROBE MAPPING HASH : ". Dumper(%probe_hash)."\n";
    return (\%probe_hash,$warning);
}

sub parse_gse_sample_info_for_platform
{
    my $lines_array_ref = shift;
    my @lines = @{$lines_array_ref}; 

    my $gsm_id = undef;
    my %gsm_platform_info_hash; #Hash that has GSMID as key (or "ALL_GSMS" as single key) -> {"organism"=>value,          
                                #                                                             "taxID"=>value,      
                                #                                                             "platform"=>GPLID}       
    foreach my $line (@lines) 
    {
        if ($line =~ m/^\^SAMPLE = /)
        {
            my @temp_arr = split(/\s*=\s*/,$line); 
            $gsm_id = trim($temp_arr[1]);
        } 
        if ($line =~ m/^\!Sample_taxid_ch1 = /) 
        { 
            my @temp_arr = split(/\s*=\s*/,$line); 
            $gsm_platform_info_hash{$gsm_id}->{"taxID"} = trim($temp_arr[1]); 
        } 
        if ($line =~ m/^\!Sample_organism_ch1 = /)
        { 
            my @temp_arr = split(/\s*=\s*/,$line);
            $gsm_platform_info_hash{$gsm_id}->{"organism"} = trim($temp_arr[1]); 
        }
        if ($line =~ m/^\!Sample_platform_id = /) 
        { 
            my @temp_arr = split(/\s*=\s*/,$line); 
            $gsm_platform_info_hash{$gsm_id}->{"platform"} = trim($temp_arr[1]); 
        } 
    }
    return \%gsm_platform_info_hash;
}


sub parse_gse_sample_portion
{
    my $metaDataOnly = shift;
    my $platform_hash_ref = shift;
    my $platform_tax_genome_probe_feature_hash_ref = shift;
    my $lines_array_ref = shift;
    my @lines = @{$lines_array_ref};

    my %gsm_hash;
    my $gsm_id = undef;
    my $gsm_title = undef;
    my $gsm_description = undef;
    my %gsm_molecule_hash;
    my $gsm_molecule = undef;
    my $gsm_submission_date = undef;
    my $gsm_tax_id = undef;
    my $gsm_sample_organism = undef;
    my @gsm_sample_characteristics = ();
    my @gsm_protocols_array = ();
    my $gsm_value_type = undef;
    my $gsm_original_log2_median = undef;
    my $gsm_contact_email = undef;
    my $gsm_contact_first_name = undef;
    my $gsm_contact_last_name = undef;
    my $gsm_contact_institution = undef;

    my $gpl_id = undef;

    my $sample_table_start = undef;
    my $sample_line_counter = 0;

    #print "\nPARSE_GSE_SAMPLE_PORTION Platform hash : ". Dumper($platform_hash_ref)."\n";

    foreach my $line (@lines)
    { 
        if ($line =~ m/^\^SAMPLE = /)
        { 
            my @temp_arr = split(/\s*=\s*/,$line); 
            $gsm_id = trim($temp_arr[1]);
        } 
        if ($line =~ m/^\!Sample_title = /)
        { 
            my @temp_arr = split(/\s*=\s*/,$line);
            $gsm_title = trim($temp_arr[1]); 
        }
        if ($line =~ m/^\!Sample_description = /)
        { 
            my @temp_arr = split(/\s*=\s*/,$line);
            $gsm_description = trim($temp_arr[1]); 
        }
        if ($line =~ m/^\!Sample_molecule_ch. = /)
        {
            my @temp_arr = split(/\s*=\s*/,$line);
            $gsm_molecule_hash{trim($temp_arr[0])} = trim($temp_arr[1]);
        } 
        if ($line =~ m/^\!Sample_submission_date = /)
        { 
            my @temp_arr = split(/\s*=\s*/,$line);
            $gsm_submission_date = trim($temp_arr[1]); 
        }
        if ($line =~ m/^\!Sample_taxid_ch1 = /)
        { 
            my @temp_arr = split(/\s*=\s*/,$line);
            $gsm_tax_id = trim($temp_arr[1]); 
        }
        if ($line =~ m/^\!Sample_characteristics_ch1 = /)
        { 
            my @temp_arr = split(/\s*=\s*/,$line);
            push(@gsm_sample_characteristics,trim($temp_arr[1])); 
        }
        if (($line =~ m/^\!Sample_treatment_protocol_ch1 = /) ||
	    ($line =~ m/^\!Sample_growth_protocol_ch1 = /))
	{
	    push(@gsm_protocols_array,$line);
	}
	if ($line =~ m/^\!Sample_organism_ch1 = /)
	{
	    my @temp_arr = split(/\s*=\s*/,$line);
            $gsm_sample_organism = trim($temp_arr[1]);
	}
        if ($line =~ m/^\!Sample_contact_email = /) 
        { 
            my @temp_arr = split(/\s*=\s*/,$line);
            $gsm_contact_email = trim($temp_arr[1]);
        } 
        if ($line =~ m/^\!Sample_contact_name = /) 
        { 
            my @temp_arr = split(/\s*=\s*/,$line);
	    my @temp_arr2 = split(/\,/,trim($temp_arr[1]));
	    $gsm_contact_first_name = trim($temp_arr2[0]);
	    if (scalar(@temp_arr2) == 2)
	    {
		$gsm_contact_last_name = trim($temp_arr2[1]);
	    }
            if (scalar(@temp_arr2) == 3)
            {
                $gsm_contact_last_name = trim($temp_arr2[2]); 
            }
        } 
        if ($line =~ m/^\!Sample_contact_institute = /)
        {
            my @temp_arr = split(/\s*=\s*/,$line);
            $gsm_contact_institution = trim($temp_arr[1]);
        } 
	if ($line =~ m/^\!Sample_platform_id = /)
	{ 
	    my @temp_arr = split(/\s*=\s*/,$line);
	    $gpl_id = trim($temp_arr[1]);
	}
        #IF DATA try to see if pvalue or Zscore present
	#will do later if ever
        if ($line =~ m/^\#ID_REF =/)
        { 
            $sample_table_start = $sample_line_counter;
            last; 
        } 
	$sample_line_counter++;
    }

    unless(defined($gsm_id))
    {
        $gsm_hash{"UNKNOWN GSM ID"}->{"errors"} = ["COULD NOT FIND THE GSM ID"];
	return \%gsm_hash;
    }
    else
    {
	my @emp_array;
	$gsm_hash{$gsm_id}->{"warnings"}=[]; 
	$gsm_hash{$gsm_id}->{"errors"}=[]; 
	$gsm_hash{$gsm_id}->{"gsmID"}=$gsm_id;
    }

    #check for metadata only warnings errors
    unless(defined($gsm_title)) 
    { 
        push(@{$gsm_hash{$gsm_id}->{"warnings"}},"The sample has no title");
    } 
    $gsm_hash{$gsm_id}->{"gsmTitle"}=$gsm_title;
    unless(defined($gsm_description))
    {
	$gsm_description = $gsm_title;
    }
    $gsm_hash{$gsm_id}->{"gsmDescription"}=$gsm_description;

    #NEED TO ADD SOME LOGIC FOR MOLECULE TYPE (some will not be allowed - logratio )
    #Sample Molecules
    #Possible values for each channel: total RNA, polyA RNA, cytoplasmic RNA, nuclear RNA, genomic DNA, protein, or other
    #Only can process 
    #LOG LEVEL: Total RNA / Genomic DNA
    #PolyA RNA / Genomic DNA
    #Cytoplasmic RNA / Genomic DNA
    #Total RNA
    #Genomic DNA
    #PolyA RNA
    #Cytoplasmic RNA
    my %accepted_molecule_hash = ('total rna' => 1, 
				  'polya rna' =>1,
				  'cytoplasmic rna' => 1,
				  'nuclear rna' => 1, 
				  'genomic dna' => 1, 
				  'protein' => 1);

    if (scalar(keys(%gsm_molecule_hash)) > 2)
    {
        push(@{$gsm_hash{$gsm_id}->{"errors"}},"The sample has more than 2 molecule types.");
    }
    elsif ((scalar(keys(%gsm_molecule_hash)) == 1) || (scalar(keys(%gsm_molecule_hash)) == 2)) 
    { 
        if (defined($gsm_molecule_hash{"!Sample_molecule_ch1"}))
        { 
            if (lc($gsm_molecule_hash{"!Sample_molecule_ch1"}) eq 'genomic dna')
            { 
                push(@{$gsm_hash{$gsm_id}->{"errors"}}, 
                     "This is sample has Genomic DNA in channel 1.");
            } 
            elsif(defined($accepted_molecule_hash{lc($gsm_molecule_hash{"!Sample_molecule_ch1"})}))
            { 
                $gsm_molecule = $gsm_molecule_hash{"!Sample_molecule_ch1"};
            } 
            else
            { 
                push(@{$gsm_hash{$gsm_id}->{"errors"}}, 
                     "The molecule type in channel 1 is not an accepted type.");
            }
        } 
	else 
	{ 
	    push(@{$gsm_hash{$gsm_id}->{"errors"}}, 
		 "The molecule type has 1 or 2 entries, but none map to channel 1."); 
	} 
    } 
    #print "\nMOLECULE HASH : \n".Dumper(\%gsm_molecule_hash)."\n";
    if (scalar(keys(%gsm_molecule_hash)) == 2)
    {
        if (defined($gsm_molecule_hash{"!Sample_molecule_ch2"}))
        {
	    if ($gsm_molecule_hash{"!Sample_molecule_ch2"} ne "Genomic DNA")
	    {
		push(@{$gsm_hash{$gsm_id}->{"errors"}},
		     "This is a 2 channel array with the 2nd array not being Genomic DNA.  This suggests log ratio and not log level values.");
	    }
	    else
	    {
		$gsm_molecule .= " / " . $gsm_molecule_hash{"!Sample_molecule_ch2"};
	    }
        }
        else 
        { 
            push(@{$gsm_hash{$gsm_id}->{"errors"}}, 
                 "The molecule type has 2 entries, but none map to channel 2.");
        } 
    }
    $gsm_hash{$gsm_id}->{"gsmMolecule"}=$gsm_molecule; 
    $gsm_hash{$gsm_id}->{"gsmSubmissionDate"}=$gsm_submission_date; 
    unless(defined($gsm_tax_id))
    { 
        push(@{$gsm_hash{$gsm_id}->{"errors"}},"The sample has no tax id.  Will not be able to get feature ids for this.");
    } 
    $gsm_hash{$gsm_id}->{"gsmTaxID"}=$gsm_tax_id; 
    $gsm_hash{$gsm_id}->{"gsmSampleOrganism"}=$gsm_sample_organism;
    $gsm_hash{$gsm_id}->{"gsmSampleCharacteristics"}=\@gsm_sample_characteristics;
    my $gsm_protocol = join(' :: ',sort(@gsm_protocols_array));
    $gsm_hash{$gsm_id}->{"gsmProtocol"}=$gsm_protocol;


    #Get Contact person info 
    unless(defined($gsm_contact_email)) 
    { 
        push(@{$gsm_hash{$gsm_id}->{"warnings"}},"The sample has no contact email."); 
    } 
    my %contact_hash = ($gsm_contact_email => {"contactFirstName" => $gsm_contact_first_name, 
                                               "contactLastName" => $gsm_contact_last_name, 
                                               "contactInstitution" => $gsm_contact_institution}); 
    $gsm_hash{$gsm_id}->{"contactPeople"}=\%contact_hash; 


    #GET Platform Info (propogate platfrom warnings and errors)
    my $platform_passed = 1;
    if(!(defined($gpl_id)))
    {
        push(@{$gsm_hash{$gsm_id}->{"warnings"}},"The sample does not have a platform");
    }
    elsif(!defined($platform_hash_ref->{$gpl_id}))
    {
        push(@{$gsm_hash{$gsm_id}->{"warnings"}},"The platform $gpl_id was not found in the platform hash");
    }
    else
    {
	my @we_types = ("warnings","errors");
	foreach my $we_type (@we_types)
	{
	    foreach my $we_msg (@{$platform_hash_ref->{$gpl_id}->{$we_type}})
	    {
		push(@{$gsm_hash{$gsm_id}->{$we_type}},$we_msg);
		if ($we_type eq "errors")
		{
		    $platform_passed = 0;
		}
	    }
	}
	my %gpl_hash = ("gplID" => $gpl_id,
		     "gplTitle" => $platform_hash_ref->{$gpl_id}->{"gplTitle"},
		     "gplTaxID" => $platform_hash_ref->{$gpl_id}->{"gplTaxID"},
		     "gplTechnology" => $platform_hash_ref->{$gpl_id}->{"gplTechnology"},
		     "gplOrganism" => $platform_hash_ref->{$gpl_id}->{"gplOrganism"});
	$gsm_hash{$gsm_id}->{"gsmPlatform"}=\%gpl_hash;
	$gsm_hash{$gsm_id}->{"gsmFeatureMappingApproach"} = $platform_hash_ref->{$gpl_id}->{"mapping_method"};
    }


    #PARSE GEO SAMPLE DATA
    #print "\nAT PARSE GEO SAMPLE DATA \n";
    #print "\nMETADATA ONLY : $metaDataOnly   PLATFORM PASSED $platform_passed \n";

    if (($metaDataOnly eq '0') && ($platform_passed == 1))
    { 
        $gsm_hash{$gsm_id}->{"gsmValueType"}=$gsm_value_type; 
        #PARSE VALUE SECTION OF THE GSM                                             
        #CALL FUNCTION FOR VALUES SECTION.  PASSES GSM, GSM_ID_FEATURE_HASH_REF, VALUE TYPE, LINE ($sample_table_start, @lines size)
	my @sample_data_lines = @lines[$sample_table_start..(scalar(@lines)-2)];

	my $genome_probe_feature_hash_ref = $platform_tax_genome_probe_feature_hash_ref->{$gpl_id}->{$gsm_tax_id};
        #print "GENOME PROBE FEATURE HASH : ".Dumper($genome_probe_feature_hash_ref);
        my ($gsm_data_hash_ref,$gsm_value_type,$temp_gsm_value_errors_ref) = 
	    parse_sample_data($gsm_id,$genome_probe_feature_hash_ref,\@sample_data_lines);

	$gsm_hash{$gsm_id}->{"gsmData"}=$gsm_data_hash_ref;
	$gsm_hash{$gsm_id}->{"gsmValueType"}=$gsm_value_type;	
        push(@{$gsm_hash{$gsm_id}->{"errors"}},@{$temp_gsm_value_errors_ref});
        #print "GSM HASH : ".Dumper(\%gsm_hash);
    } 

    #DATA (only if metadata only = 0)(original median).
    #FEATURE MAPPING APPROACH (only if metadata only = 0).
    #only populate value if not metadata only

    #If not metadata only check for warnings/errors (intensity type, value ranges, reasonable number of mapped genes)
    #map to values to features average across all probes that hit that feature.
    
    return \%gsm_hash;
} #END  parse_gse_sample_portion 

sub parse_sample_data
{
    my $gsm_id = shift;
    my $genome_probe_feature_hash_ref = shift;
    my $lines_ref = shift;

    my %genome_probe_feature_hash = %{$genome_probe_feature_hash_ref}; #key {$genome_id->{probe id from platform => feature_id}

    my @lines = @{$lines_ref};  #Lines of data section plus value information as well other potential column headers
    my $gsm_mapping_hash_key = $gsm_id; 

    my $gsm_value_type;
    my $confidence_type;
    my @warnings;
    my @errors;
    my $gsm_value_multiplier;
    my $gsm_treatment;

    my $table_begin_hit = 0;
    while ($table_begin_hit == 0)
    {
	my $line = shift(@lines);
        if ($line =~ m/^\#VALUE = /)
        { 
            my @temp_arr = split(/\s*=\s*/,$line);
            $gsm_value_type = trim($temp_arr[1]);
        } 
	if ($line =~ m/^\!sample_table_begin/)
	{ 
	    $table_begin_hit = 1;
	} 
	#ADD determining of confidence type pValue/Zscore.
    }

    if (defined($gsm_value_type))
    {
	if (($gsm_value_type =~ m/ log/i)||($gsm_value_type =~ m/^log/i)){
	    if (($gsm_value_type =~ m/ log[ _]?10/i) || ($gsm_value_type =~ m/^log[ _]?10/i)){
		$gsm_value_multiplier = 3.3219;
		$gsm_treatment="log10";
	    }elsif (($gsm_value_type =~ m/ log[ _]?2/i) || ($gsm_value_type =~ m/^log[ _]?2/i))
	    {
		$gsm_value_multiplier = 1;
		$gsm_treatment="log2";
	    }else{
		$gsm_value_multiplier = 'ERROR';
		push(@errors,"The value contained log but could not be determined in what space.");
	    }
	}
	elsif (($gsm_value_type =~ m/^ln /i) || ($gsm_value_type =~ m/ ln /i)){
	    $gsm_value_multiplier = 1.4427;
	    $gsm_treatment="ln";
	}elsif (($gsm_value_type =~ m/[ ]?RMA[\. ]?/) || ($gsm_value_type =~ m/[ ]?Robust Multichip Average[\. ]?/))
	{
	    #May need to include MAS 5 as well.
	    $gsm_value_multiplier = 1;
	    $gsm_treatment="log2";
	}else {#need to take log2 of the value
	    $gsm_value_multiplier = 'log2';
	    $gsm_treatment="intensity";
	}
    }
    else
    {
	push(@errors,"A value type was not able to be determined");
    }

#ONLY HERE DUE TO PROBLEM WITH TEST FILE
#$gsm_treatment="intensity";
#$gsm_value_multiplier = "log2";

    my $id_ref_row_index = undef;
    my $value_row_index = undef;
    my @gsm_value_headers = split(/\t/,shift(@lines)); 
    my $gsm_header_index = 0;
    foreach my $gsm_value_header (@gsm_value_headers)
    {
	$gsm_value_header = trim($gsm_value_header);
	if ($gsm_value_header =~ m/^ID_REF$/i){
	    $id_ref_row_index = $gsm_header_index;
	}elsif ($gsm_value_header =~ m/^VALUE$/i){
	    $value_row_index = $gsm_header_index;
	}               
	$gsm_header_index++;
    }

    my %gsm_data_hash;

    #print "\n\nGenome Probe Feature Hash : ". Dumper(\%genome_probe_feature_hash) ;

    #Calculate data for all genomes 
    foreach my $genome_id (keys(%genome_probe_feature_hash))
    {
	my %feature_id_data_hash; 
	#Key feature_id->{values->[array of values in log2 space]    (Used later to determine mean, N, stddev and  median   
	#                 Zscores->[array of Zscore values]   (avg used later to determine average Zscore)        
	#                 pValue->[array of pValue values]   (avg used later to determine average pValue)  

	my $max_seen_value = undef; 
	my $min_seen_value = undef;

        #IF THE VALUE IS INTENSITY then keep track of positive and negative (good for data sanity_checks)    
	my $gsm_number_positive_values = 0;
	my $gsm_number_negative_values = 0;

	my @data_value_errors;

        my %probe_mapping_hash = undef;
	%probe_mapping_hash = %{$genome_probe_feature_hash{$genome_id}};  #Key = platform ID, value = featureID      
        #print "\n\nProbe Feature Hash : ". Dumper(\%probe_mapping_hash) ;
        foreach my $line (@lines) 
        {
            my @temp_arr = split(/\t/,$line);
            my $temp_value = trim($temp_arr[$value_row_index]);
            my $temp_id = trim($temp_arr[$id_ref_row_index]);
  
            if (defined($probe_mapping_hash{$temp_id}))
            {
                #The probe was able to be mapped to a feature.  
                my $feature_id = $probe_mapping_hash{$temp_id};
                if (($temp_value ne '') &&
                    ($temp_value =~ m/^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/))
                {
		    my $transformed_value;
                    if((!(defined($max_seen_value))) || ($temp_value > $max_seen_value))
                    {
			$max_seen_value = $temp_value;
		    }
		    if((!(defined($min_seen_value))) || ($temp_value < $min_seen_value))
		    { 
			$min_seen_value = $temp_value;
		    }
		    if($gsm_value_multiplier ne 'ERROR')
		    {
			if($gsm_value_multiplier eq 'log2')
			{
			    if ($temp_value > 0 )
			    {
				$transformed_value = log($temp_value)/log(2);
				$gsm_number_positive_values++;
			    }
			    else
			    { #means this is an intensity with a value of zero or less (they should be positive, cannot put into log2 space)
				$transformed_value = "ERROR : Negative Intensity";
				$gsm_number_negative_values++;
			    }
			}
			else
			{
			    $transformed_value = $temp_value * $gsm_value_multiplier;
			}
		    }
		    #add entries into the hash to keep track of locus_ids (count and sum(in log2 space))
		    if($transformed_value ne "ERROR : Negative Intensity")
		    {
			push(@{$feature_id_data_hash{$feature_id}->{"values"}},$transformed_value); 
		    }
		}
	    }
	}

	#DO sanity checks on the high and low to see if the ranges are reasonable
	my ($pass_max_range,$pass_min_range) = data_value_sanity_checks($gsm_treatment,$max_seen_value,$min_seen_value);
	if ($pass_max_range == 0)
	{
	    push(@data_value_errors,"The data value range for $gsm_id in genome $genome_id is too large to be reasonable");
	}
	if ($pass_min_range == 0)
	{
	    push(@data_value_errors,"The data value range for $gsm_id in genome $genome_id is too small to be reasonable");
	}
	#do checks on positive and negative numbers
	if($gsm_value_multiplier eq 'log2')
	{ 
	    if ( ($gsm_number_negative_values / ($gsm_number_positive_values + $gsm_number_negative_values )) > 0.05)
	    {
		#too many negative values for an intensity levels.
		push(@data_value_errors,"The data value for $gsm_id in genome $genome_id is intensity but it contained more than 5% negative values");
	    }
	}
        $gsm_data_hash{$genome_id}->{"errors"} = [];
        $gsm_data_hash{$genome_id}->{"warnings"} = [];
	if (scalar(@data_value_errors) > 0)
	{
	    $gsm_data_hash{$genome_id}->{"errors"} = \@data_value_errors;
	}
	else
	{
	    #Data looks good go ahead and determine the values
	    my @feature_intensity_means;
	    foreach my $temp_feature_id (keys(%feature_id_data_hash))
	    {
		my @temp_values = @{$feature_id_data_hash{$temp_feature_id}->{"values"}};
		my @intensity_values;
		foreach my $temp_value (@temp_values)
		{
		    push(@intensity_values,(2 ** $temp_value));
		}
		my $stat = Statistics::Descriptive::Full->new();
		$stat->add_data(@intensity_values); 
		my $intensity_mean = $stat->mean();
		my $log2_mean = log($intensity_mean)/log(2); 
		push(@feature_intensity_means,$intensity_mean);
		$gsm_data_hash{$genome_id}->{"features"}->{$temp_feature_id}->{"mean"}=$log2_mean;
		$gsm_data_hash{$genome_id}->{"features"}->{$temp_feature_id}->{"N"}=scalar(@temp_values);
		if (scalar (@temp_values) > 1)
		{
		    my $intensity_std_dev = $stat->standard_deviation();
		    my $log2_std_dev = (log($intensity_mean + $intensity_std_dev)/log(2)) - (log($intensity_mean)/log(2)); 
		    $gsm_data_hash{$genome_id}->{"features"}->{$temp_feature_id}->{"stddev"}=$log2_std_dev;
		    my $intensity_median = $stat->median();
                    my $log2_median = log($intensity_median)/log(2);
		    $gsm_data_hash{$genome_id}->{"features"}->{$temp_feature_id}->{"median"}=$log2_median;
		}
	    }
	    my $total_stat = Statistics::Descriptive::Full->new();
	    $total_stat->add_data(@feature_intensity_means);
	    my $original_log2_median = log($total_stat->median())/log(2);
	    $gsm_data_hash{$genome_id}->{"originalLog2Median"} = $original_log2_median;
	    #MAKE THE MEDIAN OF ALL FEATURES ZERO
	    foreach my $temp_feature_id (keys(%{$gsm_data_hash{$genome_id}->{"features"}}))
	    {
		if (defined($gsm_data_hash{$genome_id}->{"features"}->{$temp_feature_id}->{"median"}))
                {
                    $gsm_data_hash{$genome_id}->{"features"}->{$temp_feature_id}->{"median"} = 
		         $gsm_data_hash{$genome_id}->{"features"}->{$temp_feature_id}->{"median"} - $original_log2_median;
                }
#		if (defined($gsm_data_hash{$genome_id}->{"features"}->{$temp_feature_id}->{"stddev"}))
#		{
#                    $gsm_data_hash{$genome_id}->{"features"}->{$temp_feature_id}->{"stddev"} = 
#		         $gsm_data_hash{$genome_id}->{"features"}->{$temp_feature_id}->{"stddev"} - $original_log2_median;
#		}
		$gsm_data_hash{$genome_id}->{"features"}->{$temp_feature_id}->{"mean"} = 
		    $gsm_data_hash{$genome_id}->{"features"}->{$temp_feature_id}->{"mean"} - $original_log2_median; 
	    }
	}
    }
    return (\%gsm_data_hash,$gsm_value_type,\@errors);
}
#End parse_sample_data

sub data_value_sanity_checks
{
    # Loose Sanity check for data values (max compared to min)
    # Range (Max to Min) of values within a GSM seem off - 
    # Log 2 (Difference from Max and Min should be between 1.8 and 23)
    # Log 10 (Difference from Max and Min should be between 0.542 and 6.924)
    # ln (natural log) (Difference from Max and Min should be between 1.248 and 15.942)
    # Intensity (max/min) should be greater than 3.482 
    
    my $value_treatment = shift;
    my $max_value = shift;
    my $min_value = shift;
    my $pass_max_range = 1;
    my $pass_min_range = 1;

    if($value_treatment eq "intensity")
    {
	#Max Sanity is automatically ok for intensity as if background is subtracted out it may have a huge multiple.                
	if ($min_value == 0)
	{
	    $min_value = .001;
	}
        if (($max_value/$min_value) < 3.482 )
        {#means the range is too small
	    $pass_min_range = 0; 
        }
        #Max Sanity is automatically ok for intensity as if background is subtracted out it may have a huge multiple.
    }
    elsif($value_treatment eq "log2"){
	if (($max_value - $min_value) > 23)
        {#means the range is too large
        
	    $pass_max_range = 0; 
        }
        elsif (($max_value - $min_value) < 1.8)
        {#means the range is too small
	    $pass_min_range = 0; 
        }
    }
    elsif($value_treatment eq "log10"){
	if (($max_value - $min_value) > 6.924)
        {#means the range is too large
	    $pass_max_range = 0; 
        }
        elsif (($max_value - $min_value) < 0.542)
        {#means the range is too small
	    $pass_min_range = 0; 
        }
    }
    elsif($value_treatment eq "ln"){
	if (($max_value - $min_value) > 15.942)
        {#means the range is too large
	    $pass_max_range = 0; 
        }
        elsif (($max_value - $min_value) < 1.248)
        {#means the range is too small
	    $pass_min_range = 0; 
        } 
    }
    return ($pass_max_range,$pass_min_range);
}#End data_value_sanity_checks




sub get_GEO_GSE_data
{
    my $self = shift;
    my($gse_input_id, $metaDataOnly) = @_;

    my @_bad_arguments;
    (!ref($gse_input_id)) or push(@_bad_arguments, "Invalid type for argument \"gse_input_id\" (value was \"$gse_input_id\")");
    (!ref($metaDataOnly)) or push(@_bad_arguments, "Invalid type for argument \"metaDataOnly\" (value was \"$metaDataOnly\")");
    if (@_bad_arguments) {
	my $msg = "Invalid arguments passed to get_GEO_GSE:\n" . join("", map { "\t$_\n" } @_bad_arguments);
	Bio::KBase::Exceptions::ArgumentValidationError->throw(error => $msg,
							       method_name => 'get_GEO_GSE');
    }

    my $ctx = $Bio::KBase::ExpressionServices::Service::CallContext;
    my($gseObject);
    #BEGIN get_GEO_GSE
    $gseObject ={};

    if (($metaDataOnly eq "1") || (uc($metaDataOnly) eq "Y") || (uc($metaDataOnly) eq "TRUE")) 
    { 
        $metaDataOnly = 1;
    } 
    else
    {
        $metaDataOnly = 0;
    }
 
    my $gse_url = 'ftp://ftp.ncbi.nih.gov/pub/geo/DATA/SOFT/by_series/' . $gse_input_id . "/"; 
    my $gzip_file_ls_line = get($gse_url); 
    my @gse_file_records = split (/\n/,$gzip_file_ls_line); 
    foreach my $gse_record (@gse_file_records) 
    { 
	if (scalar(@gse_file_records) > 1)
	{
	    $gseObject->{"gseErrors"}->[0] = "Error there appears to multiple GSE SOFT files associated with $gse_input_id :  ".
		"These are the records listed ". join(",",@gse_file_records).".";
	    return($gseObject);
	}

	#print "GSE RECORD : $gse_record \n"; 
	my @line_segments = split (/GSE/,$gse_record); 
	my $gzip_file = "GSE".$line_segments[-1]; 
	#print "GZIP FILE : $gzip_file \n"; 
	chomp($gzip_file); 
	my $gzip_url = $gse_url.$gzip_file; 
	my $gzip_output = get($gzip_url); 
 
	my $gse_output = new IO::Uncompress::Gunzip \$gzip_output 
	    or die "IO::Uncompress::Gunzip failed: $GunzipError\n"; 
 
	my $line_count = 0;

	my @gse_lines = <$gse_output>;

	#series vars 
	my $gse_series_line_start = undef;
	my $gse_series_line_end = undef;
	my $gse_series_section_parsed = 0;
	my $listed_gsm_hash_ref;

	#platform vars
	my @platform_start_lines; #start lines for each platform in the platforms section
	my @platform_end_lines; #start lines for each platform in the platforms section
	my %platform_hash; #key is the platform name

	#vars for dealing with mapping probes to features
	my %gsm_platform_info_hash;  #Hash that has GSMID as key (or "ALL_GSMS" as single key) -> {"organism"=>value,                
                                #                                                             "taxID"=>value,     
                                #                                                             "platform"=>GPLID}     
	my %platform_tax_genome_probe_feature_hash; #key platform_id->{tax_id -> {genome_id->{probe_id -> feature_id}}}

        #sample vars  
        my @sample_start_lines; #start lines for each sample in the samples section  
        my @sample_end_lines; #start lines for each sample in the samples section 
	my %GSMs_hash; #key gsmID -> value Hash (essentially for GSM object)

	#IF METADATA ONLY = 0, means we need to deal with the Platform sections to create id->feature id hash.
        #The platform parsing section will need more information need to populate the %gsm_info_hash
	if ($metaDataOnly == 0)
	{
	    my @md_sample_start_lines;
	    my @md_sample_end_lines;
	    my $md_line_count = 0;
            my $md_looking_for_start = 1;
            foreach my $gse_line (@gse_lines) 
            { 
                if ($gse_line =~ m/^\^SAMPLE = /)
                { 
                    if ($md_looking_for_start == 0)
                    { 
                        push(@md_sample_end_lines,($md_line_count-1));
                    }
                    push(@md_sample_start_lines,$md_line_count);
                    $md_looking_for_start = 0;
                }
                if ($gse_line =~ m/^\!sample_table_end/)
                { 
                    push(@md_sample_end_lines,$md_line_count);
                    $md_looking_for_start = 1; 
                } 
                $md_line_count++;
            } 
            if($md_looking_for_start == 0)
            { 
                push(@md_sample_end_lines,($md_line_count-1)); 
            } 

	    #LOOP Through each sample and parse.                
	    if (scalar(@sample_start_lines) != scalar(@sample_end_lines)) 
	    { 
		push(@{$gseObject->{"gseErrors"}},"The samples do not have the same number of start positions (" .
		     scalar(@sample_start_lines) . 
		     ") as end positions (" . scalar(@sample_end_lines) . ")");
	    } 
	    else 
	    { 
		for (my $md_sample_counter = 0; $md_sample_counter < scalar(@md_sample_start_lines); $md_sample_counter++)
		{
		    my @md_sample_lines = @gse_lines[$md_sample_start_lines[$md_sample_counter]..$md_sample_end_lines[$md_sample_counter]]; 
		    my %temp_sample_hash = %{parse_gse_sample_info_for_platform(\@md_sample_lines)};
		    my ($temp_gsm_id) = keys(%temp_sample_hash);
		    $gsm_platform_info_hash{$temp_gsm_id} = $temp_sample_hash{$temp_gsm_id}; 
		} 
	    }
	}

	my $looking_for_start = 1; 
	foreach my $gse_line (@gse_lines)
	{ 
	    #SERIES SECTION OF GSE
	    if ($gse_line =~ m/^\^SERIES = /)
	    {
		$gse_series_line_start = $line_count;
	    }
	    if ($gse_line =~ m/^\^PLATFORM = /)
	    {
		$gse_series_line_end = $line_count -1;
	    }
	    if (defined($gse_series_line_start) && defined($gse_series_line_end) && $gse_series_section_parsed == 0)
	    {
		#need to process SERIES PORTION OF GSE
		$gse_series_section_parsed = 1;
		my @gse_portion_lines = @gse_lines[$gse_series_line_start..$gse_series_line_end];
		($gseObject,$listed_gsm_hash_ref) = parse_gse_series_portion(\@gse_portion_lines,$gseObject);
	    }

	    #PLATFORM(S) SECTION OF GSE
            if ($gse_line =~ m/^\^PLATFORM = /)
            { 
                push(@platform_start_lines,$line_count);
		my @temp_arr = split(/\s*=\s*/,$gse_line);
		my $gplID = trim($temp_arr[1]);
		$platform_hash{$gplID}={"processed" => 0}; 
            } 
	    if ($gse_line =~ m/^\!platform_table_end/)
	    {
		push(@platform_end_lines,$line_count);
	    }
            if (($gse_line =~ m/^\^SAMPLE = /)  && ($platform_end_lines[-1] == ($line_count - 1)))
	    {
		#print "PLATFORM END LINES -1 :". $platform_end_lines[-1] . ":\nLINE COUNT -1 :".($line_count - 1)."\n";
		#need to process platform section of GSE
		if (scalar(@platform_start_lines) != scalar(@platform_end_lines))
		{
		    push(@{$gseObject->{"gseErrors"}},"The platforms do not have the same number of start positions (" . 
			 scalar(@platform_start_lines) . 
			 ") as end positions (" . scalar(@platform_end_lines) . ")");
		}
		else
		{
		    for (my $platform_counter = 0; $platform_counter < scalar(@platform_start_lines); $platform_counter++) 
		    {
			my @gse_platform_lines = @gse_lines[$platform_start_lines[$platform_counter]..$platform_end_lines[$platform_counter]];

			my ($platform_hash_ref,$temp_plt_tax_genome_probe_feat_hash_ref) = parse_gse_platform_portion(\%platform_hash,
														  $metaDataOnly,
														  \@gse_platform_lines,
														  \%gsm_platform_info_hash, 
														  $self);
			%platform_hash = %{$platform_hash_ref};
		        my ($temp_gpl_id) = keys(%{$temp_plt_tax_genome_probe_feat_hash_ref});
			$platform_tax_genome_probe_feature_hash{$temp_gpl_id}=$temp_plt_tax_genome_probe_feat_hash_ref->{$temp_gpl_id};
		    }
		}
		foreach my $temp_gpl_id (keys(%platform_hash))
		{
#
#
#THIS ERROR CHECK IS WRONG NEEDS TO BE FIXED
#PROCESSED CHECK
#
		    if ($platform_hash{$temp_gpl_id}->{"processed"} == 0)
		    {
			push(@{$gseObject->{"gseErrors"}},"GEO Platform $temp_gpl_id was not able to processed");
		    }
		}
	    }
            if ($gse_line =~ m/^\^SAMPLE = /)
            { 
                if ($looking_for_start == 0)
                { 
                    push(@sample_end_lines,($line_count-1));
                }
                push(@sample_start_lines,$line_count);
                $looking_for_start = 0;
            } 
            if ($gse_line =~ m/^\!sample_table_end/)
            { 
                push(@sample_end_lines,$line_count);
                $looking_for_start = 1; 
            } 
            $line_count++; 
        } 
        if($looking_for_start == 0) 
        { 
            push(@sample_end_lines,($line_count-1));
        }

	#LOOP Through each sample and parse.
	if (scalar(@sample_start_lines) != scalar(@sample_end_lines)) 
	{ 
	    push(@{$gseObject->{"gseErrors"}},"The samples do not have the same number of start positions (" . 
		 scalar(@sample_start_lines) . 
		 ") as end positions (" . scalar(@sample_end_lines) . ")"); 
	} 
	else 
	{
	    my $has_passing_gsm = 0;
	    for (my $sample_counter = 0; $sample_counter < scalar(@sample_start_lines); $sample_counter++) 
	    { 
		my @gse_sample_lines = @gse_lines[$sample_start_lines[$sample_counter]..$sample_end_lines[$sample_counter]]; 
		my %sample_hash = %{parse_gse_sample_portion($metaDataOnly,\%platform_hash,\%platform_tax_genome_probe_feature_hash,\@gse_sample_lines)}; 
		my ($gsm_id) = keys(%sample_hash);
		$gseObject->{"gseSamples"}->{$gsm_id} = $sample_hash{$gsm_id};
		my @sample_errors = @{$sample_hash{$gsm_id}->{"errors"}};
		if (scalar(@sample_errors) == 0)
		{
		    $has_passing_gsm = 1;
		}
		delete $listed_gsm_hash_ref->{$gsm_id};
	    } 
	    foreach my $not_parsed_gsm (keys(%{$listed_gsm_hash_ref}))
	    {
		push(@{$gseObject->{"gseErrors"}},"The sample $not_parsed_gsm was in the series header but the sample was not found in the body"); 
	    }
	    if ($has_passing_gsm == 0)
	    {
		push(@{$gseObject->{"gseErrors"}},"This GSE did not contain any GSMs that passed."); 
	    }
	}
	#print "FINAL LINE COUNT $line_count \n"; 
	#print "GSM LISTED HASH : \n".Dumper($listed_gsm_hash_ref);
    } 
    my @_bad_returns;
    (ref($gseObject) eq 'HASH') or push(@_bad_returns, "Invalid type for return variable \"gseObject\" (value was \"$gseObject\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to get_GEO_GSE:\n" . join("", map { "\t$_\n" } @_bad_returns);
	Bio::KBase::Exceptions::ArgumentValidationError->throw(error => $msg,
							       method_name => 'get_GEO_GSE');
    }
    return($gseObject);
}#End get_GEO_GSE_data




1;
