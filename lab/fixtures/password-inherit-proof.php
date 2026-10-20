<?php
/**
 * Proof-only mu-plugin: treat bbPress replies/topics as password-protected when
 * an ancestor topic or forum has a password.
 *
 * This mirrors the intent of upstream commit e0547e55 (r8057), without the
 * production recursion guard, and exists only to verify the vulnerable search
 * path in the local lab. Do not ship this file.
 */

add_filter(
	'post_password_required',
	function ( $required, $post = null ) {
		if ( $required || ! ( $post instanceof WP_Post ) || ! function_exists( 'bbp_is_custom_post_type' ) || ! bbp_is_custom_post_type( $post ) ) {
			return $required;
		}

		$ids = array( (int) $post->ID );

		if ( bbp_is_reply( $post->ID ) ) {
			$ids[] = (int) bbp_get_reply_topic_id( $post->ID );
			$ids[] = (int) bbp_get_reply_forum_id( $post->ID );
		} elseif ( bbp_is_topic( $post->ID ) ) {
			$ids[] = (int) bbp_get_topic_forum_id( $post->ID );
		}

		foreach ( array_unique( array_filter( $ids ) ) as $id ) {
			if ( '' !== (string) get_post_field( 'post_password', $id ) ) {
				return true;
			}
		}

		return $required;
	},
	10,
	2
);
