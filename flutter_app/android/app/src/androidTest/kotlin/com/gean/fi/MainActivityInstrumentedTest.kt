package com.gean.fi

import android.content.Context
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.lang.reflect.InvocationTargetException

@RunWith(AndroidJUnit4::class)
class MainActivityInstrumentedTest {
    @Test
    fun identityPersistsAndTamperedWrappingNeverRegenerates() {
        val testKey = "instrumented-device-seed"
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            var first: ByteArray? = null
            scenario.onActivity { activity ->
                val method = MainActivity::class.java.getDeclaredMethod("loadOrCreateSecret", String::class.java)
                    .apply { isAccessible = true }
                val preferences = activity.getSharedPreferences("fi-secure-wrapped-v1", Context.MODE_PRIVATE)
                preferences.edit().remove(testKey).commit()

                first = method.invoke(activity, testKey) as ByteArray
                val second = method.invoke(activity, testKey) as ByteArray
                assertArrayEquals(first, second)
            }

            scenario.recreate()
            scenario.onActivity { activity ->
                val method = MainActivity::class.java.getDeclaredMethod("loadOrCreateSecret", String::class.java)
                    .apply { isAccessible = true }
                val preferences = activity.getSharedPreferences("fi-secure-wrapped-v1", Context.MODE_PRIVATE)
                assertArrayEquals(first, method.invoke(activity, testKey) as ByteArray)

                preferences.edit().putString(testKey, "AAAA").commit()
                assertThrows(InvocationTargetException::class.java) {
                    method.invoke(activity, testKey)
                }
                preferences.edit().remove(testKey).commit()
            }
        }
    }

    @Test
    fun foregroundAcquiresAndRepeatedLifecycleAlwaysReleasesMulticastLock() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            repeat(3) {
                scenario.moveToState(Lifecycle.State.RESUMED)
                scenario.onActivity { activity ->
                    MainActivity::class.java.getDeclaredMethod("acquireMulticast")
                        .apply { isAccessible = true }
                        .invoke(activity)
                    val field = MainActivity::class.java.getDeclaredField("multicastLock")
                        .apply { isAccessible = true }
                    val lock = field.get(activity)
                    assertNotNull(lock)
                    assertTrue((lock as android.net.wifi.WifiManager.MulticastLock).isHeld)
                }
                scenario.moveToState(Lifecycle.State.STARTED)
                scenario.onActivity { activity ->
                    val field = MainActivity::class.java.getDeclaredField("multicastLock")
                        .apply { isAccessible = true }
                    assertNull(field.get(activity))
                }
            }
        }
    }
}
