package Irssi;

use strict;
use warnings;

use constant INPUT_READ => 1;
use constant INPUT_WRITE => 2;

sub import { }
sub timeout_add_once { return 1 }
sub timeout_remove { return 1 }

1;
