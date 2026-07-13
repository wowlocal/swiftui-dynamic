import Foundation
import UIKit

func platformStaticStringURLExists() -> Bool {
    URL(string: UIApplication.openSettingsURLString) != nil
}
