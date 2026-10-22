<?php
echo json_encode(array('post' => array_keys($_POST), 'files' => array_map(function ($f) { return $f['type']; }, $_FILES)));
