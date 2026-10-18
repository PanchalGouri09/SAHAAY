package com.example.sahaay

import android.content.Context
import android.location.Geocoder
import android.os.Handler
import android.os.Looper
import com.google.android.gms.common.api.ApiException
import com.google.android.libraries.places.api.Places
import com.google.android.libraries.places.api.model.AutocompletePrediction
import com.google.android.libraries.places.api.model.AutocompleteSessionToken
import com.google.android.libraries.places.api.model.Place
import com.google.android.libraries.places.api.net.FetchPlaceRequest
import com.google.android.libraries.places.api.net.FindAutocompletePredictionsRequest
import com.google.android.libraries.places.api.net.PlacesClient
import android.text.style.CharacterStyle
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.Locale

/**
 * Bridge between Flutter and the official Places SDK for Android.
 *
 * The Google Maps/Places API key never reaches Dart. It is written into
 * `AndroidManifest.xml` by the Secrets Gradle Plugin from the gitignored
 * `android/secrets.properties` (`MAPS_API_KEY`) and read back here from the
 * `com.google.android.geo.API_KEY` meta-data that the manifest already carries
 * for the Maps SDK.
 *
 * Channel: `sahaay/places`
 *   newSession     -> void                      (start a billing session)
 *   autocomplete   -> { "predictions": [...] }  (real Places Autocomplete)
 *   placeDetails   -> { latitude, longitude, address, name, placeId } | null
 *   geocode        -> { latitude, longitude } | null (real address lookup)
 *
 * No bundled or synthesised suggestions exist anywhere in this file: every
 * prediction returned comes straight from Google.
 */
class PlacesChannel(
    context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val appContext: Context = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private var client: PlacesClient? = null
    private var sessionToken: AutocompleteSessionToken =
        AutocompleteSessionToken.newInstance()

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        client = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            METHOD_NEW_SESSION -> {
                sessionToken = AutocompleteSessionToken.newInstance()
                result.success(null)
            }
            METHOD_AUTOCOMPLETE -> handleAutocomplete(call, result)
            METHOD_PLACE_DETAILS -> handlePlaceDetails(call, result)
            METHOD_GEOCODE -> handleGeocode(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleGeocode(call: MethodCall, result: MethodChannel.Result) {
        val address = call.argument<String>(ARG_ADDRESS)?.trim().orEmpty()
        if (address.isEmpty()) {
            result.success(null)
            return
        }
        if (!Geocoder.isPresent()) {
            result.error(
                ERROR_GEOCODE_UNAVAILABLE,
                "Address lookup is unavailable on this device.",
                null,
            )
            return
        }

        Thread({
            try {
                val match = Geocoder(appContext, Locale.getDefault())
                    .getFromLocationName(address, 1)
                    ?.firstOrNull()
                val coordinates = match?.let {
                    mapOf(
                        ARG_LATITUDE to it.latitude,
                        ARG_LONGITUDE to it.longitude,
                    )
                }
                mainHandler.post { result.success(coordinates) }
            } catch (error: IOException) {
                mainHandler.post {
                    result.error(
                        ERROR_GEOCODE_FAILED,
                        "Address lookup could not reach the location service.",
                        null,
                    )
                }
            } catch (error: RuntimeException) {
                mainHandler.post {
                    result.error(
                        ERROR_GEOCODE_FAILED,
                        "Address lookup failed. Please try again.",
                        null,
                    )
                }
            }
        }, "sahaay-address-geocode").start()
    }

    private fun ensureClient(result: MethodChannel.Result): Boolean {
        client?.let { return true }
        try {
            if (!Places.isInitialized()) {
                val key = appContext.applicationInfo
                    ?.metaData
                    ?.getString(PLACE_KEY_META_DATA)
                if (key.isNullOrBlank()) {
                    result.error(
                        ERROR_UNAVAILABLE,
                        "Place search is unavailable because the Google Maps " +
                            "key is not configured on this device.",
                        null,
                    )
                    return false
                }
                // Places API (New) is the only mode supported by the SDK
                // version resolved by this project.
                Places.initialize(appContext, key)
            }
            client = Places.createClient(appContext)
            return true
        } catch (error: Throwable) {
            result.error(
                ERROR_INIT_FAILED,
                error.message ?: "Could not start place search.",
                null,
            )
            return false
        }
    }

    private fun handleAutocomplete(call: MethodCall, result: MethodChannel.Result) {
        val query = call.argument<String>(ARG_QUERY)?.trim().orEmpty()
        if (query.isEmpty()) {
            result.success(emptyPredictions())
            return
        }
        if (!ensureClient(result)) return

        val request = FindAutocompletePredictionsRequest.builder()
            .setQuery(query)
            .setSessionToken(sessionToken)
            .build()

        // Task listeners added without an executor are delivered on the main
        // thread, which is where the platform channel result must be sent.
        client!!
            .findAutocompletePredictions(request)
            .addOnSuccessListener { response ->
                val predictions = response.autocompletePredictions.map { item ->
                    mapOf(
                        PLACE_ID to item.placeId,
                        PRIMARY_TEXT to primaryText(item),
                        SECONDARY_TEXT to secondaryText(item),
                        FULL_TEXT to fullText(item),
                    )
                }
                result.success(mapOf("predictions" to predictions))
            }
            .addOnFailureListener { error ->
                result.error(
                    ERROR_QUERY_FAILED,
                    userMessage(error),
                    null,
                )
            }
    }

    private fun handlePlaceDetails(call: MethodCall, result: MethodChannel.Result) {
        val placeId = call.argument<String>(ARG_PLACE_ID)?.trim().orEmpty()
        if (placeId.isEmpty()) {
            result.success(null)
            return
        }
        if (!ensureClient(result)) return

        val request = FetchPlaceRequest.builder(
            placeId,
            listOf(Place.Field.ID, Place.Field.LAT_LNG, Place.Field.ADDRESS, Place.Field.NAME),
        ).build()

        client!!
            .fetchPlace(request)
            .addOnSuccessListener { response ->
                val place = response.place
                val latLng = place.latLng
                if (latLng == null) {
                    // Google returned no coordinates for this place. Reporting
                    // null (rather than a guessed point) lets the Dart side
                    // tell the user honestly.
                    result.success(null)
                    return@addOnSuccessListener
                }
                val address = place.address?.trim().orEmpty()
                if (address.isEmpty()) {
                    result.success(null)
                    return@addOnSuccessListener
                }
                result.success(
                    mapOf(
                        PLACE_ID to place.id,
                        ARG_LATITUDE to latLng.latitude,
                        ARG_LONGITUDE to latLng.longitude,
                        ARG_ADDRESS to address,
                        ARG_NAME to place.name,
                    ),
                )
            }
            .addOnFailureListener { error ->
                result.error(
                    ERROR_FETCH_FAILED,
                    userMessage(error),
                    null,
                )
            }
    }

    private fun emptyPredictions(): Map<String, Any> =
        mapOf("predictions" to emptyList<Map<String, Any>>())

    /**
     * Turns an SDK failure into something safe to show a user. [ApiException]
     * already carries a readable status message; anything else gets a neutral
     * sentence so a stack trace or key never reaches the UI or the logs.
     */
    private fun userMessage(error: Throwable): String = when (error) {
        is ApiException -> error.status.statusMessage?.takeIf {
            it.isNotBlank() && !it.contains(PLACE_KEY_META_DATA)
        } ?: "Place search could not reach Google."
        else -> "Place search could not reach Google."
    }

    private fun primaryText(item: AutocompletePrediction): String =
        item.getPrimaryText(null as CharacterStyle?).toString()

    private fun secondaryText(item: AutocompletePrediction): String =
        item.getSecondaryText(null as CharacterStyle?).toString()

    private fun fullText(item: AutocompletePrediction): String =
        item.getFullText(null as CharacterStyle?).toString()

    companion object {
        const val CHANNEL_NAME = "sahaay/places"

        private const val METHOD_NEW_SESSION = "newSession"
        private const val METHOD_AUTOCOMPLETE = "autocomplete"
        private const val METHOD_PLACE_DETAILS = "placeDetails"
        private const val METHOD_GEOCODE = "geocode"

        private const val ARG_QUERY = "query"
        private const val ARG_PLACE_ID = "placeId"
        private const val ARG_ADDRESS = "address"
        private const val ARG_LATITUDE = "latitude"
        private const val ARG_LONGITUDE = "longitude"
        private const val ARG_NAME = "name"

        private const val PLACE_ID = "placeId"
        private const val PRIMARY_TEXT = "primaryText"
        private const val SECONDARY_TEXT = "secondaryText"
        private const val FULL_TEXT = "fullText"

        private const val PLACE_KEY_META_DATA = "com.google.android.geo.API_KEY"

        const val ERROR_UNAVAILABLE = "places_unavailable"
        const val ERROR_INIT_FAILED = "places_init_failed"
        const val ERROR_QUERY_FAILED = "places_query_failed"
        const val ERROR_FETCH_FAILED = "places_fetch_failed"
        const val ERROR_GEOCODE_UNAVAILABLE = "geocode_unavailable"
        const val ERROR_GEOCODE_FAILED = "geocode_failed"
    }
}
