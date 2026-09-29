package app.hisaab.hisaab

import org.junit.Assert.*
import org.junit.Test

class SpendingSmsParserTest {
    private val date = 1790674200000L
    private fun parse(body: String, sender: String = "VM-HDFCBK") = SpendingSmsParser.parse(body, sender, date)

    @Test fun supportedBankSendersYieldStructuredRecordsOnly() {
        val aliases = listOf("SBIINB", "HDFCBK", "ICICIB", "AXISBK", "KOTAKB", "PNBSMS", "BOBTXN", "CANBNK",
            "UNIONB", "IDFCFB", "YESBNK", "INDUSB", "AUBANK", "FEDBNK", "PAYTMB")
        for (alias in aliases) {
            val row = parse("INR 1,250.50 debited from a/c XX1234 at Swiggy on 29-09-2026. UPI Ref 123456789012. Avl Bal INR 8,700.", "VM-$alias")!!
            assertEquals(alias, 125050L, row["amountPaise"])
            assertEquals("Swiggy", row["title"])
            assertEquals("Food & cafés", row["category"])
            assertEquals("1234", row["accountLast4"])
            assertEquals("123456789012", row["reference"])
            assertFalse(row.containsKey("body"))
            assertFalse(row.containsKey("sender"))
        }
        assertNotNull(parse("INR 500 debited from a/c1234", "VM-HDFCBK-S"))
    }
    @Test fun otpPersonalAndNonCompletedMessagesNeverParse() {
        for (body in listOf("OTP 834781 for INR 500 debited from a/c 1234", "INR 500 debit failed",
            "INR 500 paid pending", "INR 500 will be debited tomorrow", "Your minimum due INR 500. You spent INR 900.",
            "UPI request received for INR 500", "Your INR 500 purchase declined")) {
            assertNull(body, parse(body))
            assertFalse(body, SpendingSmsParser.eligible(body, "VM-HDFCBK"))
        }
        assertNull(parse("INR 500 paid to me", "+919999999999"))
        assertNull(parse("HDFC INR 500 debited", "VM-UNKNOWN"))
    }
    @Test fun creditRefundP2pAndOwnTransferHaveDifferentMeaning() {
        assertEquals("credit", parse("INR 52000 credited to a/c1234 from ACME on 29-09-2026")!!["kind"])
        assertEquals("refund", parse("INR 500 refund credited to a/c1234 from Amazon on 29-09-2026")!!["kind"])
        assertEquals("transfer", parse("INR 500 debited from a/c1234 for self transfer")!!["kind"])
        assertEquals("transfer", parse("INR 500 withdrawn from a/c1234 at ATM")!!["kind"])
        val p2p = parse("INR 500 transferred to Asha via UPI from a/c1234")!!
        assertEquals("debit", p2p["kind"])
        assertEquals("Transfer to Asha", p2p["title"])
        assertEquals("Other", p2p["category"])
        assertEquals("debit", parse("INR 500 debited from a/c1234 to ACME on 29-09-2026 via UPI")!!["kind"])
    }
    @Test fun identifiersAreIdempotentAndAmountsUseBoundedIntegerPaise() {
        val sms = "Rs. 120.00 paid at Coffee Cafe on 29-09-2026 from a/c1234. UPI Ref 123456789012"
        assertEquals(parse(sms)!!["importId"], SpendingSmsParser.parse(sms, "VM-HDFCBK", date + 60000)!!["importId"])
        assertNotEquals(parse(sms)!!["importId"], parse(sms.replace("120.00", "130.00"))!!["importId"])
        assertEquals(105L, parse("INR 1.05 debited from a/c1234")!!["amountPaise"])
        assertNull(parse("INR 0 debited from a/c1234"))
        assertNull(parse("INR 1.999 debited from a/c1234"))
        assertNull(parse("INR 10000000.01 debited from a/c1234"))
        assertNull(parse("INR 500 debited and INR 500 credited"))
    }
    @Test fun balancesAreNotTransactionsAndEmbeddedAccountDigitsAreMasked() {
        assertNull(parse("Avl Bal INR 9000. INR 500 debited from a/c1234"))
        assertEquals("MERCHANT••••", parse("INR 500 debited at MERCHANT123456789012 on 29-09-2026")!!["title"])
    }
    @Test fun referenceFreeInboxAndReceiverAgreeDespiteDelayedDelivery() {
        val sms = "INR 120.00 debited from a/c1234 at Coffee Cafe on 29-09-2026"
        val sentAt = date
        val receivedAt = date + 90_123L
        val receiver = SpendingSmsParser.parse(sms, "VM-HDFCBK", sentAt)!!
        val inbox = SpendingSmsParser.parse(sms, "VM-HDFCBK", SpendingSmsParser.inboxTimestamp(sentAt, receivedAt))!!
        assertFalse(receiver.containsKey("reference"))
        assertEquals(receiver["importId"], inbox["importId"])
        assertEquals(receiver["date"], inbox["date"])
        assertNotEquals(receiver["importId"], SpendingSmsParser.parse(sms, "VM-HDFCBK", receivedAt)!!["importId"])
        assertEquals(receivedAt, SpendingSmsParser.inboxTimestamp(null, receivedAt))
        assertEquals(receivedAt, SpendingSmsParser.inboxTimestamp(0L, receivedAt))
        assertEquals(receivedAt, SpendingSmsParser.inboxTimestamp(-1L, receivedAt))
    }
    @Test fun multipartPdusKeepOneBodyAndOneIdentity() {
        val parts = listOf("INR 1250.50 debited from a/c1234 at Sw", "iggy on 29-09-2026.\u000CAvl Bal INR 8000")
        val inboxBody = "INR 1250.50 debited from a/c1234 at Swiggy on 29-09-2026.\nAvl Bal INR 8000"
        val combined = SpendingSmsParser.combineMultipart(parts)
        assertEquals(inboxBody, combined)
        val receiver = SpendingSmsParser.parse(combined, "VM-HDFCBK", date)!!
        val inbox = SpendingSmsParser.parse(inboxBody, "VM-HDFCBK", SpendingSmsParser.inboxTimestamp(date, date + 60000))!!
        assertEquals("Swiggy", receiver["title"])
        assertEquals(receiver["importId"], inbox["importId"])
        assertEquals(1, listOf(receiver["importId"], inbox["importId"]).distinct().size)
    }
    @Test fun unknownFinancialFormatsAreCountableWithoutKeepingRawText() {
        val body = "A/c1234 DR INR500.00 transaction completed"
        assertNull(parse(body))
        assertTrue(SpendingSmsParser.eligible(body, "VM-HDFCBK"))
        assertFalse(SpendingSmsParser.eligible(body, "+919999999999"))
        assertFalse(SpendingSmsParser.eligible("Meet for lunch at 500", "VM-HDFCBK"))
    }
}
