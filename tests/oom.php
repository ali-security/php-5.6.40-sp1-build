<?php
register_shutdown_function(function () { echo "shutdown ran\n"; });
$s = str_repeat('a', 16 << 20);
echo "not reached\n";
