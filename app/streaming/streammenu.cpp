#include "streammenu.h"
#include "session.h"

#include <algorithm>
#include <string>

// Four fingers landing within this window open the menu
#define MENU_GESTURE_WINDOW_MS 500
#define MENU_GESTURE_FINGERS 4

// Left stick deflection that counts as a menu navigation press
#define MENU_STICK_THRESHOLD 16000

StreamMenu::StreamMenu(Session* session)
    : m_Session(session),
      m_Open(false),
      m_Selected(ItemResume),
      m_StickDirection(0),
      m_FirstFingerDownTime(0),
      m_SwallowTouches(false),
      m_TapActive(false),
      m_TapFinger(0),
      m_TapStartedOutside(false)
{
}

void StreamMenu::open()
{
    if (m_Open) {
        return;
    }

    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "Opening stream menu");

    // Nothing pressed before the menu opened should stay held on the host
    m_Session->m_InputHandler->releaseAllInput();

    m_Open = true;
    m_Selected = ItemResume;
    m_StickDirection = 0;
    m_TapActive = false;
    refresh();
}

void StreamMenu::close()
{
    if (!m_Open) {
        return;
    }

    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "Closing stream menu");

    m_Open = false;
    m_TapActive = false;
    m_Session->getOverlayManager().hideMenu();
}

void StreamMenu::refresh()
{
    bool statsVisible = m_Session->getOverlayManager().isOverlayEnabled(Overlay::OverlayDebug);

    std::vector<std::string> items(ItemCount);
    items[ItemResume] = "Resume stream";
    items[ItemToggleStats] = statsVisible ? "Hide performance stats" : "Show performance stats";
    items[ItemDisconnect] = "Disconnect";
    items[ItemQuitGame] = "Quit game and disconnect";
    items[ItemExit] = "Exit Moonlight";

    // Size rows for fingers: about 1/12 of the screen height per row, while
    // keeping the longest label inside the screen width
    int width, height;
    getDrawableSize(width, height);
    int fontSize = SDL_max(16, SDL_min(96, SDL_min(height / 18, width / 28)));

    m_Session->getOverlayManager().showMenu("Stream menu", items, m_Selected, fontSize);
}

void StreamMenu::moveSelection(int delta)
{
    m_Selected = (m_Selected + delta + ItemCount) % ItemCount;
    refresh();
}

void StreamMenu::pushQuitEvent()
{
    SDL_Event event = {};
    event.type = SDL_QUIT;
    event.quit.timestamp = SDL_GetTicks();
    SDL_PushEvent(&event);
}

void StreamMenu::activate(int item)
{
    switch (item) {
    case ItemResume:
        close();
        break;

    case ItemToggleStats:
        m_Session->getOverlayManager().setOverlayState(Overlay::OverlayDebug,
                                                       !m_Session->getOverlayManager().isOverlayEnabled(Overlay::OverlayDebug));
        m_Selected = item;
        refresh();
        break;

    case ItemDisconnect:
        close();
        pushQuitEvent();
        break;

    case ItemQuitGame:
        m_Session->requestQuitHostApp();
        close();
        pushQuitEvent();
        break;

    case ItemExit:
        // Leaves the game running unless the user's settings say otherwise
        m_Session->setShouldExit();
        close();
        pushQuitEvent();
        break;

    default:
        break;
    }
}

void StreamMenu::getDrawableSize(int& width, int& height)
{
    // Overlays are laid out in drawable pixels, not window points
#if SDL_VERSION_ATLEAST(2, 26, 0)
    SDL_GetWindowSizeInPixels(m_Session->m_Window, &width, &height);
#else
    SDL_GetWindowSize(m_Session->m_Window, &width, &height);
#endif
}

int StreamMenu::itemAt(float normX, float normY)
{
    Overlay::MenuLayout layout;
    if (!m_Session->getOverlayManager().getMenuLayout(layout)) {
        return k_NotOnItem;
    }

    int width, height;
    getDrawableSize(width, height);

    // Renderers center the menu surface in the drawable area
    float x = normX * width - (width - layout.width) / 2.0f;
    float y = normY * height - (height - layout.height) / 2.0f;
    if (x < 0 || y < 0 || x >= layout.width || y >= layout.height) {
        return k_OutsideMenu;
    }

    if (y < layout.itemsTop) {
        return k_NotOnItem;
    }

    int row = (int)((y - layout.itemsTop) / layout.rowHeight);
    return row < layout.itemCount ? row : k_NotOnItem;
}

bool StreamMenu::handleFingerEvent(const SDL_TouchFingerEvent& event)
{
#if SDL_VERSION_ATLEAST(2, 0, 10)
    if (SDL_GetTouchDeviceType(event.touchId) != SDL_TOUCH_DEVICE_DIRECT) {
        // Trackpads are handled through the mouse path
        return m_Open;
    }
#endif

    if (event.type == SDL_FINGERDOWN) {
        if (m_ActiveFingers.empty()) {
            m_FirstFingerDownTime = event.timestamp;
        }
        m_ActiveFingers.push_back(event.fingerId);
    }
    else if (event.type == SDL_FINGERUP) {
        m_ActiveFingers.erase(std::remove(m_ActiveFingers.begin(), m_ActiveFingers.end(), event.fingerId),
                              m_ActiveFingers.end());
    }

    // Four fingers landing together toggle the menu
    if (event.type == SDL_FINGERDOWN && !m_SwallowTouches &&
            m_ActiveFingers.size() >= MENU_GESTURE_FINGERS &&
            event.timestamp - m_FirstFingerDownTime <= MENU_GESTURE_WINDOW_MS) {
        m_SwallowTouches = true;
        if (m_Open) {
            close();
        }
        else {
            open();
        }
        return true;
    }

    if (m_SwallowTouches) {
        if (m_ActiveFingers.empty()) {
            m_SwallowTouches = false;
        }
        return true;
    }

    if (!m_Open) {
        return false;
    }

    // Menu selection: the row under a single finger is highlighted, and
    // lifting the finger on a row activates it. Tapping outside resumes.
    switch (event.type) {
    case SDL_FINGERDOWN:
        if (m_ActiveFingers.size() == 1) {
            int item = itemAt(event.x, event.y);
            m_TapActive = true;
            m_TapFinger = event.fingerId;
            m_TapStartedOutside = item == k_OutsideMenu;
            if (item >= 0 && item != m_Selected) {
                m_Selected = item;
                refresh();
            }
        }
        else {
            // Multi-finger touches never select anything
            m_TapActive = false;
        }
        break;

    case SDL_FINGERMOTION:
        if (m_TapActive && event.fingerId == m_TapFinger) {
            int item = itemAt(event.x, event.y);
            if (item >= 0 && item != m_Selected) {
                m_Selected = item;
                refresh();
            }
        }
        break;

    case SDL_FINGERUP:
        if (m_TapActive && event.fingerId == m_TapFinger) {
            m_TapActive = false;

            int item = itemAt(event.x, event.y);
            if (item >= 0) {
                activate(item);
            }
            else if (item == k_OutsideMenu && m_TapStartedOutside) {
                close();
            }
        }
        break;
    }

    return true;
}

bool StreamMenu::handleEvent(const SDL_Event& event)
{
    switch (event.type) {
    case SDL_FINGERDOWN:
    case SDL_FINGERMOTION:
    case SDL_FINGERUP:
        return handleFingerEvent(event.tfinger);
    default:
        break;
    }

    if (!m_Open) {
        return false;
    }

    switch (event.type) {
    case SDL_KEYDOWN:
        switch (event.key.keysym.sym) {
        case SDLK_UP:
            moveSelection(-1);
            break;
        case SDLK_DOWN:
            moveSelection(1);
            break;
        case SDLK_RETURN:
        case SDLK_KP_ENTER:
        case SDLK_SPACE:
            activate(m_Selected);
            break;
        case SDLK_ESCAPE:
            close();
            break;
        default:
            break;
        }
        return true;

    case SDL_KEYUP:
    case SDL_TEXTINPUT:
    case SDL_MOUSEBUTTONDOWN:
    case SDL_MOUSEWHEEL:
        return true;

    case SDL_MOUSEMOTION:
    case SDL_MOUSEBUTTONUP:
    {
        // Touch-synthesized mouse events and relative mouse mode carry no
        // useful pointer position
        bool isMotion = event.type == SDL_MOUSEMOTION;
        if ((isMotion ? event.motion.which : event.button.which) == SDL_TOUCH_MOUSEID ||
                SDL_GetRelativeMouseMode()) {
            return true;
        }
        int x = isMotion ? event.motion.x : event.button.x;
        int y = isMotion ? event.motion.y : event.button.y;

        int windowWidth, windowHeight;
        SDL_GetWindowSize(m_Session->m_Window, &windowWidth, &windowHeight);
        if (windowWidth <= 0 || windowHeight <= 0) {
            return true;
        }

        int item = itemAt((float)x / windowWidth, (float)y / windowHeight);
        if (isMotion) {
            if (item >= 0 && item != m_Selected) {
                m_Selected = item;
                refresh();
            }
        }
        else if (event.button.button == SDL_BUTTON_LEFT) {
            if (item >= 0) {
                activate(item);
            }
            else if (item == k_OutsideMenu) {
                close();
            }
        }
        return true;
    }

    case SDL_CONTROLLERBUTTONDOWN:
        switch (event.cbutton.button) {
        case SDL_CONTROLLER_BUTTON_DPAD_UP:
            moveSelection(-1);
            break;
        case SDL_CONTROLLER_BUTTON_DPAD_DOWN:
            moveSelection(1);
            break;
        case SDL_CONTROLLER_BUTTON_A:
            activate(m_Selected);
            break;
        case SDL_CONTROLLER_BUTTON_B:
        case SDL_CONTROLLER_BUTTON_START:
            close();
            break;
        default:
            break;
        }
        return true;

    case SDL_CONTROLLERAXISMOTION:
        if (event.caxis.axis == SDL_CONTROLLER_AXIS_LEFTY) {
            int direction = event.caxis.value < -MENU_STICK_THRESHOLD ? -1 :
                            event.caxis.value > MENU_STICK_THRESHOLD ? 1 : 0;
            if (direction != m_StickDirection) {
                m_StickDirection = direction;
                if (direction != 0) {
                    moveSelection(direction);
                }
            }
        }
        return true;

    case SDL_CONTROLLERBUTTONUP:
#if SDL_VERSION_ATLEAST(2, 0, 14)
    case SDL_CONTROLLERSENSORUPDATE:
    case SDL_CONTROLLERTOUCHPADDOWN:
    case SDL_CONTROLLERTOUCHPADUP:
    case SDL_CONTROLLERTOUCHPADMOTION:
#endif
        return true;

    default:
        return false;
    }
}
