<?php
/**
 * Create password-protected fixtures for the reply search disclosure PoC.
 *
 * Run with WP-CLI:
 *   LEAK_MARK=abc123 wp eval-file fixtures/password-reply-search.php --user=admin
 */

$mark = getenv( 'LEAK_MARK' );
if ( empty( $mark ) ) {
	$mark = 'leak' . wp_rand( 100000, 999999 );
}

// 1. A public forum with an individually password-protected topic.
$public_forum = bbp_insert_forum(
	array(
		'post_title'   => 'POC Public Forum ' . $mark,
		'post_content' => 'Public forum',
		'post_status'  => 'publish',
	),
	array( 'forum_type' => 'forum' )
);

$password_topic = bbp_insert_topic(
	array(
		'post_parent'   => $public_forum,
		'post_title'    => 'POC Protected Topic ' . $mark,
		'post_content'  => 'TOPIC_SECRET_' . $mark,
		'post_status'   => 'publish',
		'post_password' => 'topicpass',
	)
);

$topic_reply = bbp_insert_reply(
	array(
		'post_parent'  => $password_topic,
		'post_title'   => 'POC Reply In Protected Topic ' . $mark,
		'post_content' => 'REPLY_SECRET_' . $mark,
		'post_status'  => 'publish',
	)
);

// 2. A password-protected forum with a normal topic and reply.
$password_forum = bbp_insert_forum(
	array(
		'post_title'    => 'POC Protected Forum ' . $mark,
		'post_content'  => 'Protected forum',
		'post_status'   => 'publish',
		'post_password' => 'forumpass',
	),
	array( 'forum_type' => 'forum' )
);

$forum_topic = bbp_insert_topic(
	array(
		'post_parent'  => $password_forum,
		'post_title'   => 'POC Topic In Protected Forum ' . $mark,
		'post_content' => 'FORUM_TOPIC_SECRET_' . $mark,
		'post_status'  => 'publish',
	)
);

$forum_reply = bbp_insert_reply(
	array(
		'post_parent'  => $forum_topic,
		'post_title'   => 'POC Reply In Protected Forum ' . $mark,
		'post_content' => 'FORUM_REPLY_SECRET_' . $mark,
		'post_status'  => 'publish',
	)
);

// 3. Controls: private and hidden forums must stay excluded.
$private_forum = bbp_insert_forum(
	array(
		'post_title'   => 'POC Private Forum ' . $mark,
		'post_content' => 'Private forum',
		'post_status'  => 'private',
	),
	array( 'forum_type' => 'forum' )
);

$private_topic = bbp_insert_topic(
	array(
		'post_parent'  => $private_forum,
		'post_title'   => 'POC Private Topic ' . $mark,
		'post_content' => 'PRIVATE_TOPIC_SECRET_' . $mark,
		'post_status'  => 'publish',
	)
);

$private_reply = bbp_insert_reply(
	array(
		'post_parent'  => $private_topic,
		'post_title'   => 'POC Private Reply ' . $mark,
		'post_content' => 'PRIVATE_REPLY_SECRET_' . $mark,
		'post_status'  => 'publish',
	)
);

$hidden_forum = bbp_insert_forum(
	array(
		'post_title'   => 'POC Hidden Forum ' . $mark,
		'post_content' => 'Hidden forum',
		'post_status'  => 'hidden',
	),
	array( 'forum_type' => 'forum' )
);

$hidden_topic = bbp_insert_topic(
	array(
		'post_parent'  => $hidden_forum,
		'post_title'   => 'POC Hidden Topic ' . $mark,
		'post_content' => 'HIDDEN_TOPIC_SECRET_' . $mark,
		'post_status'  => 'publish',
	)
);

$hidden_reply = bbp_insert_reply(
	array(
		'post_parent'  => $hidden_topic,
		'post_title'   => 'POC Hidden Reply ' . $mark,
		'post_content' => 'HIDDEN_REPLY_SECRET_' . $mark,
		'post_status'  => 'publish',
	)
);

echo wp_json_encode(
	array(
		'mark'             => $mark,
		'public_forum'     => $public_forum,
		'password_topic'   => $password_topic,
		'topic_reply'      => $topic_reply,
		'password_forum'   => $password_forum,
		'forum_topic'      => $forum_topic,
		'forum_reply'      => $forum_reply,
		'private_forum'    => $private_forum,
		'private_topic'    => $private_topic,
		'private_reply'    => $private_reply,
		'hidden_forum'     => $hidden_forum,
		'hidden_topic'     => $hidden_topic,
		'hidden_reply'     => $hidden_reply,
	)
);
