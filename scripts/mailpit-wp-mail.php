<?php

if (! function_exists('wp_mail')) {

	function wp_mail( $to, $subject, $message, $headers = '', $attachments = array(), $embeds = array() ) {
		// Compact the input, apply the filters, and extract them back out.

		$atts = apply_filters( 'wp_mail', compact( 'to', 'subject', 'message', 'headers', 'attachments', 'embeds' ) );

		$atts = fast_wordpress_mailpit_recipients( $atts );

		if ( isset( $atts['to'] ) ) {
			$to = $atts['to'];
		}

		if ( ! is_array( $to ) ) {
			$to = explode( ',', $to );
		}

		if ( isset( $atts['subject'] ) ) {
			$subject = $atts['subject'];
		}

		if ( isset( $atts['message'] ) ) {
			$message = $atts['message'];
		}

		if ( isset( $atts['headers'] ) ) {
			$headers = $atts['headers'];
		}

		if ( isset( $atts['attachments'] ) ) {
			$attachments = $atts['attachments'];
		}

		if ( ! is_array( $attachments ) ) {
			$attachments = explode( "\n", str_replace( "\r\n", "\n", $attachments ) );
		}

		if ( isset( $atts['embeds'] ) ) {
			$embeds = $atts['embeds'];
		}

		if ( ! is_array( $embeds ) ) {
			$embeds = explode( "\n", str_replace( "\r\n", "\n", $embeds ) );
		}

		global $phpmailer;

		$phpmailer_class_ok = $phpmailer instanceof PHPMailer\PHPMailer\PHPMailer
			&& in_array( get_class( $phpmailer ), array( PHPMailer\PHPMailer\PHPMailer::class, 'WP_PHPMailer' ), true );

		if ( ! $phpmailer_class_ok ) {
			require_once ABSPATH . WPINC . '/PHPMailer/PHPMailer.php';
			require_once ABSPATH . WPINC . '/PHPMailer/SMTP.php';
			require_once ABSPATH . WPINC . '/PHPMailer/Exception.php';

			if ( file_exists( ABSPATH . WPINC . '/class-wp-phpmailer.php' ) ) {
				require_once ABSPATH . WPINC . '/class-wp-phpmailer.php';
				$phpmailer = new WP_PHPMailer( true );
			} else {
				$phpmailer = new PHPMailer\PHPMailer\PHPMailer( true );
			}

			$phpmailer::$validator = static function ( $email ) {
				return (bool) is_email( $email );
			};
		}

		// Headers.
		$cc       = array();
		$bcc      = array();
		$reply_to = array();

		if ( empty( $headers ) ) {
			$headers = array();
		} else {
			if ( ! is_array( $headers ) ) {
				/*
				 * Explode the headers out, so this function can take
				 * both string headers and an array of headers.
				 */
				$tempheaders = explode( "\n", str_replace( "\r\n", "\n", $headers ) );
			} else {
				$tempheaders = $headers;
			}
			$headers = array();

			// If it's actually got contents.
			if ( ! empty( $tempheaders ) ) {
				// Iterate through the raw headers.
				foreach ( (array) $tempheaders as $header ) {
					if ( ! str_contains( $header, ':' ) ) {
						if ( false !== stripos( $header, 'boundary=' ) ) {
							$parts    = preg_split( '/boundary=/i', trim( $header ) );
							$boundary = trim( str_replace( array( "'", '"' ), '', $parts[1] ) );
						}
						continue;
					}
					// Explode them out.
					list( $name, $content ) = explode( ':', trim( $header ), 2 );

					// Cleanup crew.
					$name    = trim( $name );
					$content = trim( $content );

					switch ( strtolower( $name ) ) {
						// Mainly for legacy -- process a "From:" header if it's there.
						case 'from':
							$bracket_pos = strpos( $content, '<' );
							if ( false !== $bracket_pos ) {
								// Text before the bracketed email is the "From" name.
								if ( $bracket_pos > 0 ) {
									$from_name = substr( $content, 0, $bracket_pos );
									$from_name = str_replace( '"', '', $from_name );
									$from_name = trim( $from_name );
								}

								$from_email = substr( $content, $bracket_pos + 1 );
								$from_email = str_replace( '>', '', $from_email );
								$from_email = trim( $from_email );

								// Avoid setting an empty $from_email.
							} elseif ( '' !== trim( $content ) ) {
								$from_email = trim( $content );
							}
							break;
						case 'content-type':
							if ( str_contains( $content, ';' ) ) {
								list( $type, $charset_content ) = explode( ';', $content );
								$content_type                   = trim( $type );
								if ( false !== stripos( $charset_content, 'charset=' ) ) {
									$charset = trim( str_replace( array( 'charset=', '"' ), '', $charset_content ) );
								} elseif ( false !== stripos( $charset_content, 'boundary=' ) ) {
									$boundary = trim( str_replace( array( 'BOUNDARY=', 'boundary=', '"' ), '', $charset_content ) );
									$charset  = '';
									if ( preg_match( '~^multipart/(\S+)~', $content_type, $matches ) ) {
										$content_type = 'multipart/' . strtolower( $matches[1] ) . '; boundary="' . $boundary . '"';
									}
								}

								// Avoid setting an empty $content_type.
							} elseif ( '' !== trim( $content ) ) {
								$content_type = trim( $content );
							}
							break;
						case 'cc':
							$cc = array_merge( (array) $cc, explode( ',', $content ) );
							break;
						case 'bcc':
							$bcc = array_merge( (array) $bcc, explode( ',', $content ) );
							break;
						case 'reply-to':
							$reply_to = array_merge( (array) $reply_to, explode( ',', $content ) );
							break;
						default:
							// Add it to our grand headers array.
							$headers[ trim( $name ) ] = trim( $content );
							break;
					}
				}
			}
		}

		// Empty out the values that may be set.
		$phpmailer->clearAllRecipients();
		$phpmailer->clearAttachments();
		$phpmailer->clearCustomHeaders();
		$phpmailer->clearReplyTos();
		$phpmailer->Body    = '';
		$phpmailer->AltBody = '';

		/*
		 * Reset encoding to 8-bit, as it may have been automatically downgraded
		 * to 7-bit by PHPMailer (based on the body contents) in a previous call
		 * to wp_mail().
		 *
		 * See https://core.trac.wordpress.org/ticket/33972
		 */
		$phpmailer->Encoding = PHPMailer\PHPMailer\PHPMailer::ENCODING_8BIT;

		// Set "From" name and email.

		// If we don't have a name from the input headers.
		if ( ! isset( $from_name ) ) {
			$from_name = 'WordPress';
		}

		/*
		 * If we don't have an email from the input headers, default to wordpress@$sitename
		 * Some hosts will block outgoing mail from this address if it doesn't exist,
		 * but there's no easy alternative. Defaulting to admin_email might appear to be
		 * another option, but some hosts may refuse to relay mail from an unknown domain.
		 * See https://core.trac.wordpress.org/ticket/5007.
		 */
		if ( ! isset( $from_email ) ) {
			// Get the site domain and get rid of www.
			$sitename   = wp_parse_url( network_home_url(), PHP_URL_HOST );
			$from_email = 'wordpress@';

			if ( null !== $sitename ) {
				if ( str_starts_with( $sitename, 'www.' ) ) {
					$sitename = substr( $sitename, 4 );
				}

				$from_email .= $sitename;
			}
		}

		$from_email = apply_filters( 'wp_mail_from', $from_email );

		$from_name = apply_filters( 'wp_mail_from_name', $from_name );

		$from_email = fast_wordpress_mailpit_fix_localhost( $from_email );
		if ( ! is_email( $from_email ) ) {
			$from_email = 'wordpress@example.test';
		}

		try {
			$phpmailer->setFrom( $from_email, $from_name, false );
		} catch ( PHPMailer\PHPMailer\Exception $e ) {
			$mail_error_data                             = compact( 'to', 'subject', 'message', 'headers', 'attachments' );
			$mail_error_data['phpmailer_exception_code'] = $e->getCode();

			do_action( 'wp_mail_failed', new WP_Error( 'wp_mail_failed', $e->getMessage(), $mail_error_data ) );

			return false;
		}

		// Set mail's subject and body.
		$phpmailer->Subject = $subject;
		$phpmailer->Body    = $message;

		// Set destination addresses, using appropriate methods for handling addresses.
		$address_headers = compact( 'to', 'cc', 'bcc', 'reply_to' );

		foreach ( $address_headers as $address_header => $addresses ) {
			if ( empty( $addresses ) ) {
				continue;
			}

			foreach ( (array) $addresses as $address ) {
				try {
					// Break $recipient into name and address parts if in the format "Foo <bar@baz.com>".
					$recipient_name = '';

					if ( preg_match( '/(.*)<(.+)>/', $address, $matches ) ) {
						if ( count( $matches ) === 3 ) {
							$recipient_name = $matches[1];
							$address        = $matches[2];
						}
					}

					switch ( $address_header ) {
						case 'to':
							$phpmailer->addAddress( $address, $recipient_name );
							break;
						case 'cc':
							$phpmailer->addCC( $address, $recipient_name );
							break;
						case 'bcc':
							$phpmailer->addBCC( $address, $recipient_name );
							break;
						case 'reply_to':
							$phpmailer->addReplyTo( $address, $recipient_name );
							break;
					}
				} catch ( PHPMailer\PHPMailer\Exception $e ) {
					continue;
				}
			}
		}

		// Set to use PHP's mail().
		$phpmailer->isMail();

		// Set Content-Type and charset.

		// If we don't have a Content-Type from the input headers.
		if ( ! isset( $content_type ) ) {
			$content_type = 'text/plain';
		}

		$content_type = apply_filters( 'wp_mail_content_type', $content_type );

		$phpmailer->ContentType = $content_type;

		// Set whether it's plaintext, depending on $content_type.
		if ( 'text/html' === $content_type ) {
			$phpmailer->isHTML( true );
		}

		// If we don't have a charset from the input headers.
		if ( ! isset( $charset ) ) {
			$charset = get_bloginfo( 'charset' );
		}

		$phpmailer->CharSet = apply_filters( 'wp_mail_charset', $charset );

		// Set custom headers.
		if ( ! empty( $headers ) ) {
			foreach ( (array) $headers as $name => $content ) {
				// Only add custom headers not added automatically by PHPMailer.
				if ( ! in_array( $name, array( 'MIME-Version', 'X-Mailer' ), true ) ) {
					try {
						$phpmailer->addCustomHeader( sprintf( '%1$s: %2$s', $name, $content ) );
					} catch ( PHPMailer\PHPMailer\Exception $e ) {
						continue;
					}
				}
			}
		}

		if ( ! empty( $attachments ) ) {
			foreach ( $attachments as $filename => $attachment ) {
				$filename = is_string( $filename ) ? $filename : '';

				try {
					$phpmailer->addAttachment( $attachment, $filename );
				} catch ( PHPMailer\PHPMailer\Exception $e ) {
					continue;
				}
			}
		}

		if ( ! empty( $embeds ) ) {
			foreach ( $embeds as $key => $embed_path ) {
					$embed_args = apply_filters(
					'wp_mail_embed_args',
					array(
						'path'        => $embed_path,
						'cid'         => (string) $key,
						'name'        => basename( $embed_path ),
						'encoding'    => 'base64',
						'type'        => '',
						'disposition' => 'inline',
					)
				);

				try {
					$phpmailer->addEmbeddedImage(
						$embed_args['path'],
						$embed_args['cid'],
						$embed_args['name'],
						$embed_args['encoding'],
						$embed_args['type'],
						$embed_args['disposition']
					);
				} catch ( PHPMailer\PHPMailer\Exception $e ) {
					continue;
				}
			}
		}

		do_action_ref_array( 'phpmailer_init', array( &$phpmailer ) );

		fast_wordpress_mailpit_phpmailer( $phpmailer );

		$mail_data = compact( 'to', 'subject', 'message', 'headers', 'attachments', 'embeds' );

		// Send!
		try {
			$send = $phpmailer->send();

			do_action( 'wp_mail_succeeded', $mail_data );

			return $send;
		} catch ( PHPMailer\PHPMailer\Exception $e ) {
			$mail_data['phpmailer_exception_code'] = $e->getCode();

			do_action( 'wp_mail_failed', new WP_Error( 'wp_mail_failed', $e->getMessage(), $mail_data ) );

			return false;
		}
	}
}
