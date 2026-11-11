package de.markus.adi2_remote

import android.service.notification.NotificationListenerService

/**
 * Leerer Benachrichtigungs-Dienst. Android gibt Apps nur dann Zugriff auf die
 * aktiven Medien-Sitzungen anderer Apps (Musik-Apps), wenn der Nutzer
 * diesem Dienst unter „Benachrichtigungszugriff“ zugestimmt hat.
 * Benachrichtigungen selbst werden nicht gelesen.
 */
class MediaListenerService : NotificationListenerService()
