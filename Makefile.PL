use ExtUtils::MakeMaker;
WriteMakefile(
    'NAME'      => 'POE::Component::Proxy::MSN',
    'VERSION_FROM' => 'lib/POE/Component/Proxy/MSN.pm', # finds $VERSION
    'PREREQ_PM' => {
	'Test::More' => 0.32,
	'POE'        => 0.22,
    },
);
